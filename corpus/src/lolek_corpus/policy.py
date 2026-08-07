"""Classify corpus expectations and compare observed behavior."""

from __future__ import annotations

from lolek_corpus.model import (
    TERMINAL_NO_URL,
    TERMINAL_OK,
    CorpusCase,
    CorpusPolicy,
    Expectation,
    ExpectationMismatch,
    ExpectedResult,
    ExtractorSource,
    Observation,
    Outcome,
    Profile,
    TelegramMediaKind,
    Verdict,
)


def expectation_for(
    case: CorpusCase,
    expectations: CorpusPolicy,
    profile: Profile = Profile.NO_GALLERY,
    probe: bool = False,
) -> Expectation:
    """Classify a corpus case and apply its profile-specific override."""
    if case.id in expectations.default_rejected:
        expectation = Expectation(
            Outcome.REJECTED,
            expected=ExpectedResult(TERMINAL_NO_URL, media_count=0),
            reason="default URL allowlist",
        )
    elif ExtractorSource.YT_DLP in case.sources:
        expectation = Expectation(
            Outcome.SUCCESS,
            expected=ExpectedResult(
                TERMINAL_OK,
                media_count=1,
                media_kinds=(TelegramMediaKind.VIDEO,),
            ),
        )
    elif probe:
        expectation = Expectation(
            Outcome.OBSERVE, reason="no yt-dlp upstream provenance"
        )
    else:
        expectation = Expectation(
            Outcome.SKIP, reason="unclassified without gallery-dl"
        )

    override = expectations.cases_for(profile).get(case.id)
    if override is None:
        return expectation
    return Expectation(
        outcome=override.outcome or expectation.outcome,
        expected=override.expected or expectation.expected,
        acceptable=override.acceptable,
        reason=override.reason or expectation.reason,
    )


def result_mismatch(
    expected: ExpectedResult | None, observed: Observation
) -> str | None:
    """Describe the first mismatch between a stable result and an observation."""
    if expected is None:
        return "case has no expected result"
    if observed.terminal_result != expected.terminal_result:
        return (
            f"terminal result {observed.terminal_result!r}, "
            f"expected {expected.terminal_result!r}"
        )
    if (
        expected.media_count is not None
        and observed.media_count != expected.media_count
    ):
        return f"media count {observed.media_count}, expected {expected.media_count}"
    if expected.media_kinds and observed.media_kinds != tuple(
        sorted(expected.media_kinds)
    ):
        return (
            f"media kinds {observed.media_kinds!r}, "
            f"expected {sorted(expected.media_kinds)!r}"
        )
    if (
        expected.failure_reason is not None
        and observed.failure_reason != expected.failure_reason
    ):
        return (
            f"failure reason {observed.failure_reason!r}, "
            f"expected {expected.failure_reason!r}"
        )
    return None


def expectation_verdict(expectation: Expectation, observed: Observation) -> Verdict:
    """Return a semantic verdict or raise for an unreviewed result."""
    if expectation.outcome is Outcome.OBSERVE:
        return Verdict.OBSERVED
    expected_error = result_mismatch(expectation.expected, observed)
    if expected_error is None:
        if expectation.acceptable:
            return Verdict.UNEXPECTED_IMPROVEMENT
        return Verdict.PASS
    if any(
        result_mismatch(acceptable, observed) is None
        for acceptable in expectation.acceptable
    ):
        return Verdict.KNOWN_FAILURE
    raise ExpectationMismatch(expected_error)
