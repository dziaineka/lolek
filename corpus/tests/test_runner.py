"""Tests for case selection, confirmation, and reporting decisions."""

import collections
import contextlib
import io
import json
import types

from support import CorpusTestCase

from lolek_corpus import model, runner


class RunnerTest(CorpusTestCase):
    """Cover deterministic runner behavior without live services."""

    def test_interleave_cases_round_robins_services(self):
        cases = [
            self.corpus_case("t1"),
            self.corpus_case("t2"),
            self.corpus_case("x1", model.Service.TWITTER),
            self.corpus_case("x2", model.Service.TWITTER),
            self.corpus_case("x3", model.Service.TWITTER),
            self.corpus_case("y1", model.Service.YOUTUBE),
        ]
        self.assertEqual(
            [case.id for case in runner.interleave_cases(cases)],
            ["t1", "x1", "y1", "t2", "x2", "x3"],
        )

    def test_failure_kinds_distinguish_expectations_and_harness(self):
        self.assertEqual(
            runner.failure_kind(model.ExpectationMismatch("result")),
            model.FailureKind.EXPECTATION,
        )
        self.assertEqual(
            runner.failure_kind(model.CaseMismatch("capture")),
            model.FailureKind.VALIDATION,
        )
        self.assertEqual(
            runner.failure_kind(model.HarnessError("process")),
            model.FailureKind.HARNESS,
        )

    def test_failure_record_retains_observation(self):
        error = model.ExpectationMismatch("terminal result")
        error.observed = self.observation("error", 0)
        record = runner.failure_record(
            self.corpus_case("case"),
            model.Expectation(
                model.Outcome.SUCCESS,
                expected=model.ExpectedResult(model.TERMINAL_OK, media_count=1),
            ),
            error,
            1.25,
        )

        self.assertEqual(record.failure_kind, model.FailureKind.EXPECTATION)
        self.assertEqual(record.verdict, model.Verdict.REGRESSION)
        self.assertEqual(record.observed, error.observed)
        serialized = json.loads(json.dumps(record.to_json()))
        self.assertEqual(serialized["failure_kind"], "expectation")
        self.assertEqual(serialized["observed"]["terminal_result"], "error")

    def test_rate_limited_failure_is_inconclusive(self):
        error = model.ExpectationMismatch("terminal result")
        error.observed = self.observation("error", 0, rate_limited=True)
        record = runner.failure_record(
            self.corpus_case("case"),
            model.Expectation(
                model.Outcome.SUCCESS,
                expected=model.ExpectedResult(model.TERMINAL_OK, media_count=1),
            ),
            error,
            1.25,
        )

        self.assertEqual(record.status, model.ResultStatus.INCONCLUSIVE)
        self.assertEqual(record.verdict, model.Verdict.INCONCLUSIVE)

    def test_regression_confirmation(self):
        class FakeHarness:
            def __init__(self, responses):
                self.responses = list(responses)
                self.rate_limited_services: set[model.Service] = set()
                self.throttles = 0

            def throttle(self, _case):
                self.throttles += 1

            def run_case(self, _case, _expectation, _chat_id):
                response = self.responses.pop(0)
                if isinstance(response, Exception):
                    raise response
                return response

        def mismatch(reason):
            error = model.ExpectationMismatch("terminal result")
            error.observed = self.observation("error", 0, failure_reason=reason)
            return error

        expected = model.Expectation(
            model.Outcome.SUCCESS,
            expected=model.ExpectedResult(
                model.TERMINAL_OK,
                media_count=1,
                media_kinds=(model.TelegramMediaKind.VIDEO,),
            ),
        )
        case = self.corpus_case("case")
        args = types.SimpleNamespace(regression_attempts=2)
        success = self.observation(
            "ok", 1, media_kinds=(model.TelegramMediaKind.VIDEO,)
        )
        known_failure = self.observation(
            "error",
            0,
            failure_reason=model.FailureReason.EXTRACTOR_ERROR,
        )
        scenarios = [
            (
                [
                    mismatch(model.FailureReason.EXTRACTOR_ERROR),
                    mismatch(model.FailureReason.EXTRACTOR_ERROR),
                ],
                model.Verdict.REGRESSION,
            ),
            (
                [
                    mismatch(model.FailureReason.EXTRACTOR_ERROR),
                    (success, model.Verdict.PASS),
                ],
                model.Verdict.INTERMITTENT,
            ),
            (
                [
                    mismatch(model.FailureReason.ACCESS_BLOCKED),
                    (known_failure, model.Verdict.KNOWN_FAILURE),
                ],
                model.Verdict.INTERMITTENT,
            ),
            (
                [
                    mismatch(model.FailureReason.EXTRACTOR_ERROR),
                    mismatch(model.FailureReason.ACCESS_BLOCKED),
                ],
                model.Verdict.INCONCLUSIVE,
            ),
        ]
        for responses, expected_verdict in scenarios:
            with self.subTest(expected_verdict):
                harness = FakeHarness(responses)
                with contextlib.redirect_stdout(io.StringIO()):
                    record, _error = runner.run_case_with_confirmation(
                        harness, args, case, expected, 1
                    )
                self.assertEqual(record.verdict, expected_verdict)
                self.assertEqual(len(record.attempts), 2)
                self.assertEqual(harness.throttles, 2)
                if expected_verdict is model.Verdict.INTERMITTENT:
                    self.assertEqual(record.status, model.ResultStatus.WARNING)

    def test_intermittent_verdict_does_not_fail_automation(self):
        self.assertEqual(
            runner.verdict_exit_code(
                collections.Counter({model.Verdict.INTERMITTENT: 1})
            ),
            0,
        )
        self.assertEqual(
            runner.verdict_exit_code(
                collections.Counter({model.Verdict.REGRESSION: 1})
            ),
            1,
        )
        self.assertEqual(
            runner.verdict_exit_code(
                collections.Counter({model.Verdict.INCONCLUSIVE: 1})
            ),
            2,
        )
