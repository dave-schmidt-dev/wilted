"""Unit tests for labelled-break cut decisions."""
from __future__ import annotations

import unittest
from unittest import mock

from wilted_worker.ad_outcome import UNRESOLVED_SPANS_REASON
from wilted_worker.labelled_outcome import decide_labelled_outcome, serialize_labelled_audit


def break_(start, end, kind="sponsor", label="must-cut", advertisers=None):
    return {
        "start": start,
        "end": end,
        "kind": kind,
        "label": label,
        "advertisers": list(advertisers or []),
    }


class LabelledOutcomeDecisionTests(unittest.TestCase):
    def test_must_cut_sponsor_and_network_promo_are_cut(self):
        decision = decide_labelled_outcome(
            [
                break_(10.0, 20.0, kind="sponsor"),
                break_(30.0, 40.0, kind="network-promo", advertisers=["Net"]),
            ],
            100.0,
            remove_self_promotion=False,
        )
        self.assertIsNone(decision.keep_whole_reason)
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in decision.detections],
            [(10.0, 20.0, "sponsor"), (30.0, 40.0, "network-promo")],
        )
        self.assertEqual(decision.left_in, ())
        self.assertEqual(decision.breaks_proposed, 2)

    def test_acceptable_cut_is_left_in(self):
        decision = decide_labelled_outcome(
            [
                break_(10.0, 20.0),
                break_(30.0, 40.0, label="acceptable-cut"),
            ],
            100.0,
            remove_self_promotion=False,
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in decision.detections], [(10.0, 20.0)])
        self.assertEqual(len(decision.left_in), 1)
        self.assertEqual(decision.left_in[0].reason, "acceptable-cut")
        self.assertEqual((decision.left_in[0].start_s, decision.left_in[0].end_s), (30.0, 40.0))

    def test_house_promo_follows_remove_self_promotion(self):
        house = break_(10.0, 20.0, kind="house-promo")
        kept = decide_labelled_outcome([house], 100.0, remove_self_promotion=False)
        self.assertEqual(kept.detections, ())
        self.assertEqual(kept.left_in[0].reason, "house-promotion-disabled")
        cut = decide_labelled_outcome([house], 100.0, remove_self_promotion=True)
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in cut.detections], [(10.0, 20.0, "house-promo")])
        self.assertEqual(cut.left_in, ())

    def test_out_of_range_break_is_left_in_beside_a_valid_cut(self):
        decision = decide_labelled_outcome(
            [
                break_(10.0, 20.0),
                break_(-1.0, 5.0),
                break_(90.0, 120.0),
            ],
            100.0,
            remove_self_promotion=False,
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in decision.detections], [(10.0, 20.0)])
        self.assertEqual([item.reason for item in decision.left_in], ["out-of-range", "out-of-range"])
        self.assertEqual(decision.breaks_proposed, 3)

    def test_partial_ceiling_result_keeps_the_whole_original(self):
        def hold_one(detections, total_seconds, held_spans=None):
            return list(detections[:1])

        with mock.patch("wilted_worker.labelled_outcome.enforce_total_ad_share_ceiling", hold_one):
            decision = decide_labelled_outcome(
                [break_(10.0, 20.0), break_(30.0, 40.0)],
                100.0,
                remove_self_promotion=False,
            )
        self.assertEqual(decision.detections, ())
        self.assertEqual(decision.keep_whole_reason, UNRESOLVED_SPANS_REASON)
        self.assertEqual(decision.breaks_proposed, 2)

    def test_share_ceiling_keeps_the_whole_original(self):
        decision = decide_labelled_outcome(
            [break_(0.0, 70.0)],
            100.0,
            remove_self_promotion=False,
        )
        self.assertEqual(decision.detections, ())
        self.assertEqual(decision.keep_whole_reason, UNRESOLVED_SPANS_REASON)
        self.assertTrue(decision.held_spans)
        self.assertTrue(all(reason == "total-share-ceiling" for _, _, reason in decision.held_spans))
        audit = serialize_labelled_audit(decision, {
            "labellerModelID": "deepseek-v4.1-flash",
            "labellerLevel": "low",
            "labellerPromptVersion": "labeller-prompt-v1",
        })
        self.assertEqual(audit["adEngine"], "labelled")
        self.assertEqual(audit["breaksProposed"], 1)
        self.assertEqual(audit["breaksCut"], 0)
        self.assertEqual(audit["incompleteError"], UNRESOLVED_SPANS_REASON)
        self.assertTrue(audit["warning"].startswith("original audio includes ads:"))
        self.assertEqual(audit["labellerModelID"], "deepseek-v4.1-flash")
        self.assertEqual(audit["labellerLevel"], "low")
        self.assertEqual(audit["labellerPromptVersion"], "labeller-prompt-v1")


if __name__ == "__main__":
    unittest.main()
