"""Podcast worker tests."""
from __future__ import annotations
import ast
import importlib.util
import inspect
import io
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from dataclasses import dataclass, field
from pathlib import Path
from unittest import mock
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import commercial_recovery as _worker_commercial_recovery
from wilted_worker import commercial_seeds as _worker_commercial_seeds
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import edge_recovery as _worker_edge_recovery
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import span_bounds as _worker_span_bounds
from wilted_worker import tail_recovery as _worker_tail_recovery
from wilted_worker import transcript_sources as _worker_transcript_sources
from worker_test_support import *
from worker_test_fake_llm import *
from worker_test_fake_ads import *
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import transcript_sources as _worker_transcript_sources

class GlossaryTests(unittest.TestCase):
    """The show-notes glossary, with a fixed dictionary so the system word
    list's gaps do not decide what passes."""

    DICTIONARY = frozenset("""
    a the and of is are it this week in tech at big why spending trillion higher than seems
    police hiding their use surveillance cameras flock apple online platform lawsuit
    dismiss concede meta vision pro air tag using use see me plate for mean back center data
    future volt hidden reveal trash rare book train head court landmark trial
    """.split())
    NOTES = (
        "Meta faces a $1.4 trillion lawsuit, and Flock cameras are sparking a revolt.\n\n"
        "- Meta heads to court in a landmark trial\n"
        "- Why Big Tech's AI Spending Is $3 Trillion Higher Than It Seems\n"
        "- Hidden Airtag reveals Amazon is trashing rare books to train AI\n"
        "- Police Are Hiding Their Use of Flock Surveillance Cameras\n"
        "- Go Flock Yourself\n"
        "- Apple is laying off staffers working on the Vision Pro and Siri\n"
        "- NVIDIA to Back Ohio Data Center\n\n"
        "Host: Leo Laporte (https://twit.tv/people/leo-laporte)\n\n"
        "Guests: Sam Abuelsamid and Fr. Robert Ballecer, SJ (https://bsky.app/profile/padresj)\n\n"
        "Sponsors:\n- adaptivesecurity.com (https://www.adaptivesecurity.com/?utm_campaign=2026_NA_Podcast)\n"
        "- claude.ai/technology\n"
    )

    def glossary(self):
        return wp.build_glossary(self.NOTES, "TWiT 1098: Usain Volt - Meta and the Future", self.DICTIONARY)

    def test_names_sites_and_products_are_found_and_headline_words_are_not(self):
        terms = self.glossary()
        for expected in ["Leo Laporte", "Sam Abuelsamid", "Vision Pro", "NVIDIA", "Siri", "adaptivesecurity.com",
                         "claude.ai", "twit.tv", "Usain", "Laporte", "Abuelsamid", "Ballecer", "Airtag", "Amazon"]:
            self.assertIn(expected, terms)
        for unwanted in ["Why", "Spending", "Higher", "Seems", "Police", "Hiding", "Their", "Use", "Surveillance",
                         "Meta's", "Tech's", "AI", "NA", "Podcast", "Host", "Guests", "Sponsors", "Back", "Hidden"]:
            self.assertNotIn(unwanted, terms)
        # "Meta" and "Flock" are ordinary words that earn a casing rule only by
        # being written capitalized three times and never in lower case.
        self.assertIn("Flock", terms)
        self.assertIn("Meta", terms)
        self.assertEqual(terms[0], "Fr Robert Ballecer SJ", "longest phrase first so it wins over its parts")
        self.assertEqual(wp.build_glossary("", "", self.DICTIONARY), [])

    def test_exact_hits_take_the_notes_casing_and_keep_possessives(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte said meta's vision pro and flock cameras"}]
        out, edits = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "Leo Laporte said Meta's Vision Pro and Flock cameras")
        self.assertEqual(edits, 4)
        self.assertEqual(cues[0]["text"], "leo laporte said meta's vision pro and flock cameras", "input is not mutated")

    def test_near_misses_are_respelled_but_real_words_are_left_alone(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": (
            "sama boul samad joined us on twit dot t v and adaptive security dot com sponsors us "
            "while nvidia's chips ship and everyone is using an air tag and see me later"
        )}]
        out, _ = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], (
            "Sam Abuelsamid joined us on twit.tv and adaptivesecurity.com sponsors us "
            "while NVIDIA's chips ship and everyone is using an Airtag and see me later"
        ))

    def test_marks_around_a_corrected_name_survive_it(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "That is Sam Abul Samed. \"Meta's\" (nvidia), leo laporte!"}]
        out, _ = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "That is Sam Abuelsamid. \"Meta's\" (NVIDIA), Leo Laporte!")

    def test_the_stage_is_reported_and_never_fatal(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "hello nvidia"}]
        with redirect_stderr(io.StringIO()) as err:
            out = wp.polish_with_notes({"episodeNotes": self.NOTES}, cues)
        self.assertEqual(out[0]["text"], "hello NVIDIA")
        stages = [json.loads(line)["stage"] for line in err.getvalue().splitlines()]
        self.assertEqual(stages, ["transcript.glossary.terms", "transcript.glossary.complete"])
        self.assertEqual(wp.polish_with_notes({}, cues), cues, "no notes, no pass")
        with mock.patch.object(_worker_glossary, "build_glossary", side_effect=RuntimeError("boom")):
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(wp.polish_with_notes({"episodeNotes": "x"}, cues), cues)
        self.assertIn("transcript.glossary.failed", err.getvalue())

    def test_a_term_at_the_very_start_and_end_of_a_cue_is_matched(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte opened the show for nvidia"}]
        out, edits = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "Leo Laporte opened the show for NVIDIA")
        self.assertEqual(edits, 2)

    def test_a_cue_of_only_punctuation_is_left_alone(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "... -- !!!"}]
        out, edits = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "... -- !!!")
        self.assertEqual(edits, 0)
        self.assertIs(out[0], cues[0], "an untouched cue is the same object, not a copy")

    def test_an_empty_glossary_returns_the_cues_untouched(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte said hello"}]
        out, edits = wp.apply_glossary(cues, [], self.DICTIONARY)
        self.assertEqual(edits, 0)
        self.assertIs(out, cues, "no glossary is a no-op, not a copy")

    def test_an_unchanged_cue_is_the_identical_object_a_changed_one_is_not(self):
        untouched = {"startSeconds": 0, "endSeconds": 1, "text": "nothing here matches anything"}
        changed = {"startSeconds": 1, "endSeconds": 2, "text": "leo laporte spoke"}
        out, edits = wp.apply_glossary([untouched, changed], self.glossary(), self.DICTIONARY)
        self.assertEqual(edits, 1)
        self.assertIs(out[0], untouched, "apply_glossary must not copy cues it does not edit")
        self.assertIsNot(out[1], changed, "an edited cue is a new dict, so the input is never mutated")
        self.assertEqual(changed["text"], "leo laporte spoke", "input is not mutated")

    def test_a_locked_span_is_not_re_matched_by_a_shorter_term(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte was there"}]
        # "Laporte" alone is a near-miss of nothing inside "Leo Laporte" once
        # the longer term has claimed those words; a second, shorter term must
        # not carve a piece back out of an already-corrected name.
        out, edits = wp.apply_glossary(cues, ["Leo Laporte", "Laporte"], self.DICTIONARY)
        self.assertEqual(out[0]["text"], "Leo Laporte was there")
        self.assertEqual(edits, 1)

    def test_url_hosts_with_hyphens_and_digits_are_captured(self):
        notes = "Sponsors:\n- join-bilt.com\n- web3.com\n- gpt4.dev\n"
        terms = wp.build_glossary(notes, "", self.DICTIONARY)
        for expected in ["join-bilt.com", "web3.com", "gpt4.dev"]:
            self.assertIn(expected, terms)

    def test_names_with_unicode_letters_are_recognised(self):
        # A regression check: `_WORD` is `[A-Za-z0-9][A-Za-z0-9'&.-]*`, which
        # does not match a letter like "ö". Before this is fixed, "Söderberg"
        # splits into "S" and "derberg" and the guest's name never becomes a
        # glossary term at all -- the exact failure this feature exists to fix.
        notes = "Guest: Erik Söderberg joins us this week."
        terms = wp.build_glossary(notes, "", self.DICTIONARY)
        self.assertIn("Erik Söderberg", terms)

    def test_notes_beyond_the_32kib_cap_still_produce_a_bounded_glossary(self):
        # The 32 KiB cap on stored notes is enforced upstream (Swift); this
        # worker takes whatever `episodeNotes` it is handed, so it must not
        # choke on, or unboundedly grow terms for, a large payload.
        lines = [f"- Guest: Speaker Number{i} joins to discuss Product{i} Corp\n" for i in range(600)]
        notes = "".join(lines)
        self.assertGreater(len(notes.encode("utf-8")), 32 * 1024)
        terms = wp.build_glossary(notes, "", self.DICTIONARY)
        self.assertEqual(len(terms), wp.GLOSSARY_MAXIMUM_TERMS, "the term list is capped, not left to grow with the notes")
        self.assertTrue(all(t.startswith("Speaker Number") or t.startswith("Product") for t in terms))
