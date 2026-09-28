"""Worker module split from wilted_pipeline.py."""
from __future__ import annotations
import contextlib
import difflib
import errno
import fcntl
import html
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

PREROLL_PROGRAM_START_PROMPT = """\
The excerpt is the beginning of a podcast episode. Advertising is sometimes inserted before the
program starts: a produced commercial, a trailer for another show, or a promotional spot voiced by
someone who does not appear on this program. Find the first ID at which the program itself begins.
The program's own opening, its title, its host introductions, its unstructured banter, and its
reporting or discussion of the episode's own subject all count as program. A passage that promotes a
product, a service, or another show is advertising however conversational its voice. Return 0 when
the program begins immediately and nothing precedes it. Use only a supplied ID.
Return only the strict JSON object {"program_start_id": ID}, with no prose or Markdown."""

PREROLL_CONFIRM_PROMPT = """\
The excerpt is the opening of a podcast episode, believed to be entirely advertising or promotion
carried before the program starts. Find the first ID that belongs to the program itself rather than
to advertising or promotion. Host introductions, the show title, unstructured banter, and the show's
own reporting or discussion of the episode's subject all belong to the program. A passage that
promotes a product, a service, or another show is advertising however conversational its voice.
Return -1 when no supplied ID belongs to the program. Use only a supplied ID or -1.
Return only the strict JSON object {"program_id": ID}, with no prose or Markdown."""

BOUNDARY_SEGMENT_PROMPT = """\
The excerpt is one passage from a podcast episode, taken from inside a stretch of advertising.
Answer whether the program itself starts somewhere inside this passage. The program is the show's
own content: its title, its host introductions, its reporting or discussion. A passage that is
advertising from beginning to end does not start the program, even if the advertisement ends in it.
Return only the strict JSON object {"starts_program": true} or {"starts_program": false}, with no
prose or Markdown."""

OVERSIZED_SPAN_PROGRAM_START_PROMPT = """\
The excerpt is a passage from a podcast episode that a detector classified entirely as advertising,
and it is too long for that to be true. Find the first ID at which the program itself resumes. The
program's own reporting, discussion, interviews, host introductions, and unstructured banter all
count as program; read advertisements, sponsor messages, promotional spots for other shows, and
their calls to action do not. Return the first supplied ID when the program starts immediately.
Return -1 when the passage is advertising throughout. Use only a supplied ID or -1.
Return only the strict JSON object {"program_start_id": ID}, with no prose or Markdown."""

OVERSIZED_SPAN_CONFIRM_PROMPT = """\
The excerpt is a passage from the middle of a podcast episode, believed to be entirely advertising
or promotion. Find the first ID that belongs to the program itself rather than to advertising or
promotion. The program's own reporting, discussion, interviews, host introductions, and unstructured
banter belong to the program. Return -1 when no supplied ID belongs to the program. Use only a
supplied ID or -1.
Return only the strict JSON object {"program_id": ID}, with no prose or Markdown."""

OVERSIZED_SPAN_RESCAN_PROMPT = """\
This passage was classified as advertising and a first review could not find where the program
resumes inside it, so the classification is now in doubt and is being checked a second time. Do not
look for a boundary. Look for positive evidence that the passage is a paid advertisement at all: a
named sponsor or advertiser being sold, a product or service offered for purchase, a call to action,
a destination URL, a promotional code, a discount or trial offer, or the scripted framing of a
produced spot. The show's own reporting, interviews, host introductions, unstructured banter,
credits, and promotions for the show itself are not advertising, however long they run and however
much of the episode they occupy -- a short news episode may legitimately be mostly advertising, so
length is not evidence either way. Return the ID of the single clearest piece of advertising
evidence. Return -1 when the passage carries no such evidence. Use only a supplied ID or -1.
Return only the strict JSON object {"advertisement_evidence_id": ID}, with no prose or Markdown."""

AD_POD_CONTINUATION_PROMPT = """\
The excerpt begins immediately after a verified commercial in a podcast. It may begin with a
second produced advertisement, a second sponsor message, or a promotion for another podcast. Find the first supplied ID at
which this podcast's programme resumes. Its title, host introduction, reporting, discussion, or
interview count as programme. A second produced advertisement, a second sponsor message, or a promotion for another podcast is not programme. Return -1 when no
programme resumption is visible in the supplied excerpt. Use only a supplied ID or -1.
Return only the strict JSON object {"program_start_id": ID}, with no prose or Markdown."""

POSTROLL_PROGRAM_END_PROMPT = """\
The excerpt is the end of a podcast episode. Advertising is sometimes appended after the program
finishes: a produced commercial, or a promotional spot for a different show, voiced by someone who
does not appear on this program. Find the first ID at which the program has finished and appended
advertising runs from there to the end. The program's own sign-off, its credits, its thanks and
corrections, a teaser for its own next episode, and a request to subscribe to this show all count as
program. Return -1 when the program runs all the way to the end and nothing is appended. Use only a
supplied ID or -1.
Return only the strict JSON object {"advertising_start_id": ID}, with no prose or Markdown."""

POSTROLL_CONFIRM_PROMPT = """\
The excerpt is the end of a podcast episode, believed to be a commercial, or a promotion for a
different program, appended after this program finished. Find the first ID that belongs to this
program itself. Only this program's own voice counts: its reporting or discussion, its sign-off,
its credits, its thanks and corrections, or a teaser for its own next episode. A passage that
promotes a different show is advertising even when it asks the listener to subscribe, and a passage
selling a product is advertising however it ends. Most of the time nothing here belongs to the
program, and -1 is the expected answer. Use only a supplied ID or -1.
Return only the strict JSON object {"program_id": ID}, with no prose or Markdown."""

BOUNDARY_SEGMENT_TAIL_PROMPT = """\
The excerpt is one passage from the end of a podcast episode, taken from inside a stretch of
advertising. Answer whether the program itself is still running somewhere inside this passage. The
program is the show's own content: its reporting or discussion, its sign-off, its credits, its
thanks. A passage that is advertising from beginning to end does not carry the program, even if the
program ended just before it.
Return only the strict JSON object {"carries_program": true} or {"carries_program": false}, with no
prose or Markdown."""

COMMERCIAL_EVIDENCE_NOMINATION_PROMPT = """\
Review this bounded podcast envelope. A call to action and destination were observed in the
envelope, but that is evidence to review, not permission to cut. Return the supplied global IDs
that are definitely one non-empty contiguous spoken commercial read. The answer must include the
observed commercial evidence. Return only strict JSON with no prose: {"ad_ids":[ID,...]}."""

COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT = """\
Review this bounded podcast envelope independently. Classify each ID listed under "IDs to classify",
reading the rest as context. "commercial": the whole passage is advertising -- a sponsor message, a
produced spot, a promotion for a different show, or a host-read promoting a product, service, offer,
or destination, with its call to action. A host's anecdote, question, or scene-setting that leads
directly into the product pitch is part of the commercial when the whole cue serves that pitch.
"programme": the passage is this show's own content -- its
reporting, discussion, interviews, narration, a teaser for what comes after the break, credits, or a
request to support or subscribe to this show. "mixed": the passage holds both. Return only strict
JSON with no prose."""

COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT = """\
Review this bounded podcast envelope to resolve conflicting promotional evidence for the specified
candidate ID. The candidate ID contains a promotional call to action or sponsor destination URL/code,
but was initially classified as programme. Read the whole context to decide its true role.
"commercial": the candidate cue is wholly part of a commercial advertisement or sponsor message,
including its call to action, website address, promo code, or offer details.
"programme": the candidate cue belongs to the podcast's own editorial content (reporting, discussion,
interview, narration, host intro, show credits, cold open, or self-promotion for this show itself).
"mixed": the candidate cue contains both commercial advertisement and show programme content.
Return only strict JSON with no prose: {"classification": "commercial" | "programme" | "mixed"}."""

COMMERCIAL_PREFIX_ROLE_PROMPT = """\
Review this complete pause-bracketed podcast passage. A later ID inside the passage carries observed
commercial evidence, but several earlier IDs were called programme in a broad cue-by-cue review.
Judge the specified earlier prefix as one continuous passage. Is its entire role a host-read
commercial setup that leads directly into the later product, service, or offer? A personal anecdote,
problem statement, rhetorical question, or scene-setting can be a commercial setup when it is
clearly part of that pitch. An actual show discussion, report, interview, host introduction, teaser,
credit, or self-promotion is programme. Any passage containing both is mixed. Treat the programme
before and after the bracket as boundaries, not part of the prefix. Return only strict JSON with
no prose: {"classification": "commercial" | "programme" | "mixed"}."""

COMMERCIAL_PREFIX_CUE_PROMPT = """\
Review each specified ID in this pause-bracketed podcast passage separately. The earlier passage
may be a commercial setup leading into later observed commercial evidence, but a whole-passage
judgment does not authorize cutting a mixed or editorial cue. Label an ID commercial only if its entire
speech is part of that sponsor setup or pitch, including a connected anecdote or problem statement.
Label the show's own discussion, report, interview, introduction, teaser, or credits programme.
If an ID contains both commercial and programme, label it mixed. Return only strict JSON with no prose."""

EXPERIMENTAL_NOMINATION_PROMPT = """\
Review the bounded podcast context. Return only the supplied global IDs that are definitely spoken
advertising and form one contiguous candidate. Context on both sides is programme, not permission to
extend a cut. Return only strict JSON with no prose: {"ad_ids":[ID,...]}."""
