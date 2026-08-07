"""Tests for corpus expectation policy semantics."""

import dataclasses

from support import CorpusTestCase

from lolek_corpus import model, policy


class PolicyTest(CorpusTestCase):
    """Cover expectation derivation and semantic verdicts."""

    def test_expectation_for_no_gallery(self):
        expectations = model.CorpusPolicy(
            default_rejected=frozenset({"blocked"}),
            profiles={model.Profile.NO_GALLERY: {}},
        )
        gallery_source = (model.ExtractorSource.GALLERY_DL,)
        rejected = self.corpus_case("blocked", sources=gallery_source)
        video = self.corpus_case("video")
        gallery = self.corpus_case("gallery", sources=gallery_source)

        self.assertEqual(
            policy.expectation_for(rejected, expectations).outcome,
            model.Outcome.REJECTED,
        )
        video_expectation = policy.expectation_for(video, expectations)
        self.assertIsNotNone(video_expectation.expected)
        assert video_expectation.expected is not None
        self.assertEqual(
            video_expectation.expected.media_kinds,
            (model.TelegramMediaKind.VIDEO,),
        )
        self.assertEqual(
            policy.expectation_for(gallery, expectations).outcome,
            model.Outcome.SKIP,
        )
        self.assertEqual(
            policy.expectation_for(gallery, expectations, probe=True).outcome,
            model.Outcome.OBSERVE,
        )

    def test_profile_specific_policy(self):
        override = model.CasePolicy(outcome=model.Outcome.OBSERVE)
        expectations = model.CorpusPolicy(
            default_rejected=frozenset(),
            profiles={model.Profile.GALLERY: {"case": override}},
        )

        expectation = policy.expectation_for(
            self.corpus_case("case"), expectations, model.Profile.GALLERY
        )

        self.assertEqual(expectation.outcome, model.Outcome.OBSERVE)

    def test_expectation_verdicts_reviewed_alternatives(self):
        expectation = model.Expectation(
            model.Outcome.SUCCESS,
            expected=model.ExpectedResult(
                model.TERMINAL_OK,
                media_count=1,
                media_kinds=(model.TelegramMediaKind.VIDEO,),
            ),
            acceptable=(
                model.ExpectedResult(
                    model.TERMINAL_ERROR,
                    media_count=0,
                    failure_reason=model.FailureReason.AUTHENTICATION_REQUIRED,
                ),
            ),
        )
        success = self.observation(
            "ok", 1, media_kinds=(model.TelegramMediaKind.VIDEO,)
        )
        known = self.observation(
            "error",
            0,
            failure_reason=model.FailureReason.AUTHENTICATION_REQUIRED,
        )
        changed = dataclasses.replace(
            known, failure_reason=model.FailureReason.EXTRACTOR_ERROR
        )

        self.assertEqual(
            policy.expectation_verdict(expectation, success),
            model.Verdict.UNEXPECTED_IMPROVEMENT,
        )
        self.assertEqual(
            policy.expectation_verdict(expectation, known),
            model.Verdict.KNOWN_FAILURE,
        )
        with self.assertRaises(model.ExpectationMismatch):
            policy.expectation_verdict(expectation, changed)
