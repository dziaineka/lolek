"""Parse and validate live corpus command-line configuration."""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from pathlib import Path

from lolek_corpus.model import Profile, RunnerConfig, Service

DEFAULT_EXPECTATIONS = Path(__file__).with_name("data") / "expectations.json"
DEFAULT_SERVICE_DELAY = 3.75
DEFAULT_GLOBAL_DELAY = 2.0
DEFAULT_JITTER = 0.5
DESCRIPTION = "Run Lolek's upstream URL corpus against live media services and Telegym."


def parse_args(argv: Sequence[str] | None = None) -> RunnerConfig:
    """Parse public runner options and Nix-provided executable paths."""
    parser = argparse.ArgumentParser(prog="live-corpus", description=DESCRIPTION)
    parser.add_argument(
        "--corpus", type=Path, required=True, help="JSON Lines corpus to execute"
    )
    parser.add_argument(
        "--expectations",
        type=Path,
        default=DEFAULT_EXPECTATIONS,
        help="JSON expectation policy (default: bundled policy)",
    )
    parser.add_argument(
        "--profile",
        type=Profile,
        choices=tuple(Profile),
        default=Profile.NO_GALLERY,
        help="Lolek configuration and expectation profile (default: no-gallery)",
    )
    parser.add_argument(
        "--lolek", type=Path, required=True, help="Lolek release executable"
    )
    parser.add_argument(
        "--telegym", type=Path, required=True, help="Telegym mock executable"
    )
    parser.add_argument(
        "--ffprobe", type=Path, required=True, help="ffprobe executable"
    )
    parser.add_argument(
        "--probe",
        action="store_true",
        help="run accepted gallery-only cases without asserting their terminal outcome",
    )
    parser.add_argument(
        "--case",
        action="append",
        default=[],
        dest="case_ids",
        help="run one exact case ID; may be repeated",
    )
    parser.add_argument(
        "--service",
        action="append",
        default=[],
        dest="services",
        type=parse_service,
        help="run one service; may be repeated",
    )
    parser.add_argument(
        "--limit", type=positive_int, help="run at most this many cases"
    )
    parser.add_argument(
        "--service-delay",
        type=non_negative_float,
        default=DEFAULT_SERVICE_DELAY,
        metavar="SECONDS",
        help=(
            "minimum delay between live cases for the same service "
            f"(default: {DEFAULT_SERVICE_DELAY:g})"
        ),
    )
    parser.add_argument(
        "--global-delay",
        type=non_negative_float,
        default=DEFAULT_GLOBAL_DELAY,
        metavar="SECONDS",
        help=(
            "minimum delay between any two live cases "
            f"(default: {DEFAULT_GLOBAL_DELAY:g})"
        ),
    )
    parser.add_argument(
        "--jitter",
        type=non_negative_float,
        default=DEFAULT_JITTER,
        metavar="SECONDS",
        help=(
            "maximum deterministic per-case service-delay jitter "
            f"(default: {DEFAULT_JITTER:g})"
        ),
    )
    parser.add_argument(
        "--case-timeout",
        type=positive_float,
        default=330.0,
        metavar="SECONDS",
        help="terminal result timeout for one Telegram update (default: 330)",
    )
    parser.add_argument(
        "--no-cache-replay",
        action="store_true",
        help="do not inject successful URLs a second time to verify cache reuse",
    )
    parser.add_argument(
        "--regression-attempts",
        type=positive_int,
        default=1,
        metavar="COUNT",
        help="attempt unexpected results this many times before confirming a regression (default: 1)",
    )
    parser.add_argument(
        "--report", type=Path, help="write the JSON report to this path"
    )
    parser.add_argument(
        "--keep-work-dir",
        action="store_true",
        help="retain process logs, downloads, and captured media after the run",
    )
    parsed = parser.parse_args(argv)
    return RunnerConfig(
        corpus=parsed.corpus,
        expectations=parsed.expectations,
        lolek=parsed.lolek,
        telegym=parsed.telegym,
        ffprobe=parsed.ffprobe,
        profile=parsed.profile,
        probe=parsed.probe,
        case_ids=frozenset(parsed.case_ids),
        services=frozenset(parsed.services),
        limit=parsed.limit,
        service_delay=parsed.service_delay,
        global_delay=parsed.global_delay,
        jitter=parsed.jitter,
        case_timeout=parsed.case_timeout,
        no_cache_replay=parsed.no_cache_replay,
        regression_attempts=parsed.regression_attempts,
        report=parsed.report,
        keep_work_dir=parsed.keep_work_dir,
    )


def positive_int(raw: str) -> int:
    """Parse a positive integer for argparse."""
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def positive_float(raw: str) -> float:
    """Parse a positive float for argparse."""
    value = float(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def non_negative_float(raw: str) -> float:
    """Parse a non-negative float for argparse."""
    value = float(raw)
    if value < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return value


def parse_service(raw: str) -> Service:
    """Parse a supported corpus service for argparse."""
    try:
        return Service(raw)
    except ValueError as error:
        choices = ", ".join(service.value for service in Service)
        raise argparse.ArgumentTypeError(
            f"must be one of {choices}; got {raw!r}"
        ) from error
