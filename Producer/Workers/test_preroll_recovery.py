"""Regression checks for the measured opening review prompts."""
from __future__ import annotations

import unittest

from worker_test_support import wp
from wilted_worker.preroll_passage_review import WHOLE_PASSAGE_PROMPT


class PrerollPromptWordingTests(unittest.TestCase):
    def test_opening_nomination_protects_the_show_own_subject(self):
        self.assertIn("reporting or discussion", wp.PREROLL_PROGRAM_START_PROMPT)

    def test_measured_whole_passage_prompt_keeps_the_experiment_wording(self):
        self.assertIn("A brand mention alone does not prove an ad", WHOLE_PASSAGE_PROMPT)
        self.assertIn("Quotes must be exact substrings of the cited cue", WHOLE_PASSAGE_PROMPT)
        self.assertIn("comparison-only cues solely as context", WHOLE_PASSAGE_PROMPT)
