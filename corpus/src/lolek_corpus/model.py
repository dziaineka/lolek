"""Typed domain objects shared by the live corpus runner."""

from __future__ import annotations

import dataclasses
import enum
from pathlib import Path

REPORT_SCHEMA_VERSION = 4


class TerminalResult(str):
    """An extensible terminal-result label emitted by Lolek metrics."""


TERMINAL_ERROR = TerminalResult("error")
TERMINAL_NO_URL = TerminalResult("no_url")
TERMINAL_NO_USABLE_MEDIA_FILES = TerminalResult("no_usable_media_files")
TERMINAL_NO_VIDEO_FORMATS = TerminalResult("no_video_formats")
TERMINAL_OK = TerminalResult("ok")


class ContextualCaseError:
    """Attach partial case context to errors crossing the runner boundary."""

    case_log: str = ""
    observed: Observation | None = None


class HarnessError(ContextualCaseError, RuntimeError):
    """Raised when the local live-test harness cannot make progress."""


class CaseMismatch(ContextualCaseError, AssertionError):
    """Raised when a completed case fails media or cache validation."""


class ExpectationMismatch(CaseMismatch):
    """Raised when observed bot behavior differs from its expectation."""


class Profile(enum.StrEnum):
    """Supported live corpus runner configurations."""

    NO_GALLERY = "no-gallery"
    GALLERY = "gallery"


class Outcome(enum.StrEnum):
    """Supported corpus expectation outcomes."""

    SUCCESS = "success"
    REJECTED = "rejected"
    DEFAULT_LIMIT = "default_limit"
    OBSERVE = "observe"
    SKIP = "skip"


class FailureReason(enum.StrEnum):
    """Stable classifications for volatile downloader diagnostics."""

    AUTHENTICATION_REQUIRED = "authentication_required"
    ACCESS_BLOCKED = "access_blocked"
    STALE_REDIRECT = "stale_redirect"
    EXTRACTOR_ERROR = "extractor_error"
    STALE_MEDIA = "stale_media"
    DOWNLOAD_OUTPUT_MISSING = "download_output_missing"
    DEFAULT_MEDIA_LIMIT = "default_media_limit"
    NO_USABLE_MEDIA = "no_usable_media"
    NO_VIDEO_FORMATS = "no_video_formats"
    UNSUPPORTED_MEDIA = "unsupported_media"
    RATE_LIMITED = "rate_limited"
    UNCLASSIFIED = "unclassified"


class Verdict(enum.StrEnum):
    """Semantic comparison verdicts emitted by the runner."""

    PASS = "pass"
    KNOWN_FAILURE = "known_failure"
    UNEXPECTED_IMPROVEMENT = "unexpected_improvement"
    REGRESSION = "regression"
    INTERMITTENT = "intermittent"
    INCONCLUSIVE = "inconclusive"
    OBSERVED = "observed"


class FailureKind(enum.StrEnum):
    """Stable categories for failed case execution."""

    EXPECTATION = "expectation"
    VALIDATION = "validation"
    HARNESS = "harness"


class ResultStatus(enum.StrEnum):
    """High-level status retained for report consumers."""

    PASSED = "passed"
    FAILED = "failed"
    WARNING = "warning"
    INCONCLUSIVE = "inconclusive"
    OBSERVED = "observed"
    SKIPPED_RATE_LIMITED = "skipped_rate_limited"

    @classmethod
    def for_verdict(cls, verdict: Verdict) -> ResultStatus:
        """Return the report status corresponding to a semantic verdict."""
        return {
            Verdict.REGRESSION: cls.FAILED,
            Verdict.INTERMITTENT: cls.WARNING,
            Verdict.INCONCLUSIVE: cls.INCONCLUSIVE,
            Verdict.OBSERVED: cls.OBSERVED,
        }.get(verdict, cls.PASSED)


class Service(enum.StrEnum):
    """Media services represented in the upstream corpus."""

    COUB = "coub"
    FACEBOOK = "facebook"
    INSTAGRAM = "instagram"
    TIKTOK = "tiktok"
    TWITTER = "twitter"
    YOUTUBE = "youtube"


class ExtractorSource(enum.StrEnum):
    """Upstream extractor suites contributing corpus cases."""

    GALLERY_DL = "gallery-dl"
    YT_DLP = "yt-dlp"


class CorpusMediaKind(enum.StrEnum):
    """Media shapes declared by upstream extractor tests."""

    IMAGE = "image"
    IMAGE_OR_VIDEO = "image_or_video"
    VIDEO = "video"


class TelegramMediaKind(enum.StrEnum):
    """Telegram media fields supported by the live harness."""

    VIDEO = "video"
    PHOTO = "photo"
    ANIMATION = "animation"
    DOCUMENT = "document"


@dataclasses.dataclass(frozen=True)
class ExpectedResult:
    """One stable terminal result and optional Telegram media shape."""

    terminal_result: TerminalResult
    media_count: int | None = None
    media_kinds: tuple[TelegramMediaKind, ...] = ()
    failure_reason: FailureReason | None = None


@dataclasses.dataclass(frozen=True)
class Expectation:
    """Desired result and reviewed acceptable alternatives for one case."""

    outcome: Outcome
    expected: ExpectedResult | None = None
    acceptable: tuple[ExpectedResult, ...] = ()
    reason: str | None = None


@dataclasses.dataclass(frozen=True)
class CasePolicy:
    """Parsed policy overrides for one corpus case."""

    outcome: Outcome | None = None
    expected: ExpectedResult | None = None
    acceptable: tuple[ExpectedResult, ...] = ()
    reason: str | None = None


@dataclasses.dataclass(frozen=True)
class CorpusPolicy:
    """Parsed shared policy for every supported runner profile."""

    default_rejected: frozenset[str]
    profiles: dict[Profile, dict[str, CasePolicy]]

    def cases_for(self, profile: Profile) -> dict[str, CasePolicy]:
        """Return case overrides for one runner profile."""
        return self.profiles.get(profile, {})


@dataclasses.dataclass(frozen=True)
class CorpusCase:
    """One validated upstream corpus case."""

    id: str
    service: Service
    sources: frozenset[ExtractorSource]
    kinds: tuple[CorpusMediaKind, ...]
    url: str


@dataclasses.dataclass(frozen=True)
class RunnerConfig:
    """Validated command-line configuration for one runner invocation."""

    corpus: Path
    expectations: Path
    lolek: Path
    telegym: Path
    ffprobe: Path
    profile: Profile
    probe: bool
    case_ids: frozenset[str]
    services: frozenset[Service]
    limit: int | None
    service_delay: float
    global_delay: float
    jitter: float
    case_timeout: float
    no_cache_replay: bool
    regression_attempts: int
    report: Path | None
    keep_work_dir: bool


@dataclasses.dataclass(frozen=True)
class MediaReference:
    """A Telegram media kind and its Telegym file ID."""

    kind: TelegramMediaKind
    file_id: str


@dataclasses.dataclass(frozen=True)
class Capture:
    """Validated metadata for one captured Telegram upload."""

    kind: TelegramMediaKind
    file_id: str
    filename: str
    extension: str
    size: int
    sha256: str


@dataclasses.dataclass(frozen=True)
class Observation:
    """Structured behavior observed for one completed bot request."""

    terminal_result: TerminalResult
    media_count: int
    media_kinds: tuple[TelegramMediaKind, ...] = ()
    file_ids: tuple[str, ...] = ()
    rate_limited: bool = False
    failure_reason: FailureReason | None = None
    captures: tuple[Capture, ...] = ()


@dataclasses.dataclass(frozen=True)
class AttemptResult:
    """One execution attempt retained for regression confirmation."""

    verdict: Verdict
    duration_seconds: float
    observed: Observation | None = None
    failure_kind: FailureKind | None = None
    error: str | None = None

    def to_json(self) -> dict[str, object]:
        """Return the stable JSON object for this attempt."""
        result: dict[str, object] = {"verdict": self.verdict}
        if self.failure_kind is not None:
            result["failure_kind"] = self.failure_kind
        if self.error is not None:
            result["error"] = self.error
        if self.observed is not None:
            result["observed"] = dataclasses.asdict(self.observed)
        result["duration_seconds"] = self.duration_seconds
        return result


@dataclasses.dataclass(frozen=True)
class CaseResult:
    """Typed result of running or skipping one corpus case."""

    id: str
    service: Service
    status: ResultStatus
    verdict: Verdict
    expectation: Expectation | None = None
    observed: Observation | None = None
    duration_seconds: float | None = None
    failure_kind: FailureKind | None = None
    error: str | None = None
    attempts: tuple[AttemptResult, ...] = ()

    def to_json(self) -> dict[str, object]:
        """Return the stable JSON object for this case result."""
        result: dict[str, object] = {
            "id": self.id,
            "service": self.service,
            "status": self.status,
            "verdict": self.verdict,
        }
        if self.expectation is not None:
            result["expectation"] = dataclasses.asdict(self.expectation)
        if self.observed is not None:
            result["observed"] = dataclasses.asdict(self.observed)
        if self.duration_seconds is not None:
            result["duration_seconds"] = self.duration_seconds
        if self.failure_kind is not None:
            result["failure_kind"] = self.failure_kind
        if self.error is not None:
            result["error"] = self.error
        if len(self.attempts) > 1:
            result["attempts"] = [attempt.to_json() for attempt in self.attempts]
        return result


@dataclasses.dataclass(frozen=True)
class RunReport:
    """Complete typed report for one live corpus invocation."""

    profile: Profile
    probe: bool
    corpus_sha256: str
    expectations_sha256: str
    started_at: int
    finished_at: int
    work_dir: Path
    selected: int
    skipped_unclassified: int
    results: tuple[CaseResult, ...]
    rate_limited_services: tuple[Service, ...]

    def to_json(self) -> dict[str, object]:
        """Return the versioned JSON report object."""
        return {
            "schema_version": REPORT_SCHEMA_VERSION,
            "profile": self.profile,
            "probe": self.probe,
            "inputs": {
                "corpus_sha256": self.corpus_sha256,
                "expectations_sha256": self.expectations_sha256,
            },
            "started_at": self.started_at,
            "work_dir": str(self.work_dir),
            "selected": self.selected,
            "skipped_unclassified": self.skipped_unclassified,
            "results": [result.to_json() for result in self.results],
            "finished_at": self.finished_at,
            "rate_limited_services": list(self.rate_limited_services),
        }
