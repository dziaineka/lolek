"""Select, execute, and report live corpus cases."""

from __future__ import annotations

import collections
import dataclasses
import hashlib
import json
import sys
import time
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Protocol

from lolek_corpus.config import parse_args
from lolek_corpus.corpus_data import load_corpus, load_expectations
from lolek_corpus.harness import LiveCorpusHarness
from lolek_corpus.model import (
    AttemptResult,
    CaseMismatch,
    CaseResult,
    ContextualCaseError,
    CorpusCase,
    CorpusPolicy,
    Expectation,
    ExpectationMismatch,
    FailureKind,
    HarnessError,
    Observation,
    Outcome,
    ResultStatus,
    RunnerConfig,
    RunReport,
    Service,
    Verdict,
)
from lolek_corpus.policy import expectation_for
from lolek_corpus.workspace import RunWorkspace


class ConfirmationHarness(Protocol):
    """Harness operations required by regression confirmation."""

    rate_limited_services: set[Service]

    def throttle(self, case: CorpusCase, /) -> None:
        """Delay before one external-service attempt."""
        ...

    def run_case(
        self, case: CorpusCase, expectation: Expectation, chat_id: int, /
    ) -> tuple[Observation, Verdict]:
        """Execute and validate one corpus case."""
        ...


class ConfirmationConfig(Protocol):
    """Configuration consumed by regression confirmation."""

    @property
    def regression_attempts(self) -> int:
        """Maximum attempts used to confirm an unexpected result."""
        ...


def file_sha256(path: Path) -> str:
    """Hash one input file for report provenance."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def interleave_cases(cases: Sequence[CorpusCase]) -> list[CorpusCase]:
    """Round-robin service queues to avoid service-local request bursts."""
    queues = collections.OrderedDict()
    for case in cases:
        queues.setdefault(case.service, collections.deque()).append(case)
    result = []
    while queues:
        empty = []
        for service, queue in queues.items():
            result.append(queue.popleft())
            if not queue:
                empty.append(service)
        for service in empty:
            del queues[service]
    return result


def prepare_cases(
    args: RunnerConfig, cases: Sequence[CorpusCase], expectations: CorpusPolicy
) -> tuple[list[tuple[CorpusCase, Expectation]], list[tuple[CorpusCase, Expectation]]]:
    """Filter, classify, and interleave cases for one run."""
    by_id = {case.id: case for case in cases}
    rejected_ids = expectations.default_rejected
    override_ids = expectations.cases_for(args.profile).keys()
    missing_expected = (rejected_ids | override_ids) - by_id.keys()
    if missing_expected:
        raise HarnessError(
            f"expectation file refers to missing corpus IDs: {sorted(missing_expected)!r}"
        )
    unknown_ids = set(args.case_ids) - by_id.keys()
    if unknown_ids:
        raise HarnessError(f"unknown --case IDs: {sorted(unknown_ids)!r}")
    selected = []
    skipped = []
    for case in cases:
        if args.case_ids and case.id not in args.case_ids:
            continue
        if args.services and case.service not in args.services:
            continue
        expectation = expectation_for(
            case, expectations, profile=args.profile, probe=args.probe
        )
        if expectation.outcome is Outcome.SKIP:
            skipped.append((case, expectation))
        else:
            selected.append((case, expectation))
    ordered_cases = interleave_cases([case for case, _expectation in selected])
    expectation_by_id = {case.id: expectation for case, expectation in selected}
    selected = [(case, expectation_by_id[case.id]) for case in ordered_cases]
    if args.limit is not None:
        selected = selected[: args.limit]
    return selected, skipped


def write_report(path: Path, report: dict[str, object]) -> None:
    """Atomically write a structured JSON report."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def failure_kind(error: ContextualCaseError) -> FailureKind:
    """Return the stable report category for a case failure."""
    if isinstance(error, HarnessError):
        return FailureKind.HARNESS
    if isinstance(error, ExpectationMismatch):
        return FailureKind.EXPECTATION
    return FailureKind.VALIDATION


def failure_verdict(error: ContextualCaseError) -> Verdict:
    """Classify a failed attempt as a regression or inconclusive."""
    observed = error.observed
    if isinstance(error, HarnessError) or (
        observed is not None and observed.rate_limited
    ):
        return Verdict.INCONCLUSIVE
    return Verdict.REGRESSION


def regression_signature(error: ContextualCaseError) -> tuple[object, ...]:
    """Return the stable observation fields used to confirm a regression."""
    observed = error.observed
    if observed is None:
        return (failure_kind(error), str(error))
    return (
        failure_kind(error),
        observed.terminal_result,
        observed.media_count,
        observed.media_kinds,
        observed.failure_reason,
    )


def attempt_failure_record(
    error: ContextualCaseError, duration: float
) -> AttemptResult:
    """Build the typed result for one failed attempt."""
    return AttemptResult(
        verdict=failure_verdict(error),
        failure_kind=failure_kind(error),
        error=str(error),
        duration_seconds=duration,
        observed=error.observed,
    )


def failure_record(
    case: CorpusCase,
    expectation: Expectation,
    error: ContextualCaseError,
    duration: float,
    attempts: Sequence[AttemptResult] = (),
) -> CaseResult:
    """Build a typed case failure without discarding partial observations."""
    verdict = failure_verdict(error)
    return CaseResult(
        id=case.id,
        service=case.service,
        status=ResultStatus.for_verdict(verdict),
        failure_kind=failure_kind(error),
        verdict=verdict,
        expectation=expectation,
        error=str(error),
        duration_seconds=duration,
        observed=error.observed,
        attempts=tuple(attempts),
    )


def print_case_error(error: ContextualCaseError, verdict: Verdict) -> None:
    """Print one final case error and a bounded diagnostic log tail."""
    print(f"  {verdict}: {error}", flush=True)
    recent_log = error.case_log
    if recent_log:
        print("  recent Lolek log:", flush=True)
        for line in recent_log.splitlines()[-12:]:
            print(f"    {line}", flush=True)


def run_case_with_confirmation(
    harness: ConfirmationHarness,
    args: ConfirmationConfig,
    case: CorpusCase,
    expectation: Expectation,
    chat_id: int,
) -> tuple[CaseResult, ContextualCaseError | None]:
    """Run one case, retrying only unexpected expectation mismatches."""
    case_started = time.monotonic()
    maximum_attempts = (
        1 if expectation.outcome is Outcome.REJECTED else args.regression_attempts
    )
    attempts = []
    regression_errors = []
    for attempt in range(1, maximum_attempts + 1):
        if expectation.outcome is not Outcome.REJECTED:
            harness.throttle(case)
        attempt_started = time.monotonic()
        try:
            observed, verdict = harness.run_case(case, expectation, chat_id)
            attempt_duration = round(time.monotonic() - attempt_started, 3)
            attempts.append(
                AttemptResult(
                    verdict=verdict,
                    observed=observed,
                    duration_seconds=attempt_duration,
                )
            )
            if observed.rate_limited:
                harness.rate_limited_services.add(case.service)
                verdict = Verdict.INCONCLUSIVE
            elif regression_errors:
                verdict = Verdict.INTERMITTENT
            record = CaseResult(
                id=case.id,
                service=case.service,
                status=ResultStatus.for_verdict(verdict),
                verdict=verdict,
                expectation=expectation,
                observed=observed,
                duration_seconds=round(time.monotonic() - case_started, 3),
                attempts=tuple(attempts),
            )
            print(
                f"  {verdict}: {observed.terminal_result}, "
                f"media={[kind.value for kind in observed.media_kinds]}",
                flush=True,
            )
            return record, None
        except ExpectationMismatch as error:
            attempt_duration = round(time.monotonic() - attempt_started, 3)
            attempts.append(attempt_failure_record(error, attempt_duration))
            regression_errors.append(error)
            if failure_verdict(error) is Verdict.INCONCLUSIVE:
                record = failure_record(
                    case,
                    expectation,
                    error,
                    round(time.monotonic() - case_started, 3),
                    attempts,
                )
                print_case_error(error, Verdict.INCONCLUSIVE)
                return record, error
            if attempt < maximum_attempts:
                print(
                    f"  unexpected result on attempt {attempt}/{maximum_attempts}; "
                    "confirming after throttle",
                    flush=True,
                )
                continue
            record = failure_record(
                case,
                expectation,
                error,
                round(time.monotonic() - case_started, 3),
                attempts,
            )
            signatures = {regression_signature(item) for item in regression_errors}
            if len(signatures) > 1:
                record = dataclasses.replace(
                    record,
                    status=ResultStatus.for_verdict(Verdict.INCONCLUSIVE),
                    verdict=Verdict.INCONCLUSIVE,
                    error="unexpected result changed across confirmation attempts",
                )
            print_case_error(error, record.verdict)
            return record, error
        except (CaseMismatch, HarnessError) as error:
            attempts.append(
                attempt_failure_record(
                    error, round(time.monotonic() - attempt_started, 3)
                )
            )
            record = failure_record(
                case,
                expectation,
                error,
                round(time.monotonic() - case_started, 3),
                attempts,
            )
            print_case_error(error, record.verdict)
            return record, error
    raise AssertionError("unreachable confirmation loop")


def verdict_exit_code(verdict_counts: Mapping[Verdict, int]) -> int:
    """Return the automation exit code for completed semantic verdicts."""
    if verdict_counts[Verdict.REGRESSION]:
        return 1
    if verdict_counts[Verdict.INCONCLUSIVE]:
        return 2
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Run selected cases and return a conventional process status."""
    args = parse_args(argv)
    cases = load_corpus(args.corpus)
    expectations = load_expectations(args.expectations)
    selected, skipped = prepare_cases(args, cases, expectations)
    if not selected:
        raise SystemExit(
            "no runnable cases matched; use --probe for unclassified cases"
        )
    started_at = int(time.time())
    corpus_sha256 = file_sha256(args.corpus)
    expectations_sha256 = file_sha256(args.expectations)
    results = []
    interrupted = False
    with RunWorkspace(args.keep_work_dir) as workspace:
        temporary = workspace.path
        print(
            f"live corpus ({args.profile}): {len(selected)} selected, "
            f"{len(skipped)} unclassified skipped; "
            f"work dir {temporary}",
            flush=True,
        )
        harness = LiveCorpusHarness(args, temporary)
        try:
            harness.start()
            for index, (case, expectation) in enumerate(selected, start=1):
                if case.service in harness.rate_limited_services:
                    results.append(
                        CaseResult(
                            id=case.id,
                            service=case.service,
                            status=ResultStatus.SKIPPED_RATE_LIMITED,
                            verdict=Verdict.INCONCLUSIVE,
                        )
                    )
                    continue
                print(
                    f"[{index}/{len(selected)}] {case.id} ({expectation.outcome})",
                    flush=True,
                )
                record, error = run_case_with_confirmation(
                    harness, args, case, expectation, 700_000 + index
                )
                results.append(record)
                if isinstance(error, HarnessError):
                    print(
                        "  local harness failure; aborting remaining cases",
                        file=sys.stderr,
                        flush=True,
                    )
                    break
        except KeyboardInterrupt:
            interrupted = True
            print("interrupted; stopping child processes", file=sys.stderr, flush=True)
        finally:
            harness.stop()
            report = RunReport(
                profile=args.profile,
                probe=args.probe,
                corpus_sha256=corpus_sha256,
                expectations_sha256=expectations_sha256,
                started_at=started_at,
                finished_at=int(time.time()),
                work_dir=temporary,
                selected=len(selected),
                skipped_unclassified=len(skipped),
                results=tuple(results),
                rate_limited_services=tuple(sorted(harness.rate_limited_services)),
            )
            if args.report:
                write_report(args.report, report.to_json())
                print(f"report: {args.report}", flush=True)
            if args.keep_work_dir:
                print(f"retained work dir: {temporary}", flush=True)
    verdict_counts = collections.Counter(result.verdict for result in results)
    summary = ", ".join(
        f"{verdict}={count}" for verdict, count in sorted(verdict_counts.items())
    )
    print(f"summary: {len(results)} cases; {summary}", flush=True)
    if interrupted:
        return 130
    return verdict_exit_code(verdict_counts)
