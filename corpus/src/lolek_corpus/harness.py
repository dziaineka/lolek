"""Supervise Lolek and Telegym for live corpus cases."""

from __future__ import annotations

import dataclasses
import hashlib
import socket
import time
from collections.abc import Sequence
from pathlib import Path

from lolek_corpus.failures import RATE_LIMIT_PATTERN, classify_failure_reason
from lolek_corpus.ffprobe import H264_CODEC, MP4_CONTAINER, Ffprobe, MediaInfo
from lolek_corpus.lolek import Lolek
from lolek_corpus.metrics import (
    CACHE_NEW_FILE,
    CACHE_READY_TO_TELEGRAM,
)
from lolek_corpus.model import (
    TERMINAL_OK,
    Capture,
    CaseMismatch,
    CorpusCase,
    Expectation,
    HarnessError,
    MediaReference,
    Observation,
    RunnerConfig,
    Service,
    TelegramMediaKind,
    Verdict,
)
from lolek_corpus.policy import expectation_verdict
from lolek_corpus.processes import ProcessGroup, clean_environment
from lolek_corpus.telegym import Telegym

MAX_TELEGRAM_FILE_BYTES = 45_000_000
TELEGYM_FILE_STORE_BYTES = 100 * 1024 * 1024
FAKE_TOKEN = "dummy-live-corpus-token"


def unused_local_port() -> int:
    """Ask the kernel for an unused IPv4 loopback port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def deterministic_jitter(case_id: str, maximum: float) -> float:
    """Return stable jitter so concurrent scheduled runs do not synchronize."""
    if maximum == 0:
        return 0.0
    selector = int(hashlib.sha256(case_id.encode("utf-8")).hexdigest()[:8], 16)
    return maximum * selector / 0xFFFFFFFF


class LiveCorpusHarness:
    """Supervise Telegym and Lolek and execute selected corpus cases."""

    def __init__(self, args: RunnerConfig, work_dir: Path) -> None:
        self.args = args
        self.work_dir = work_dir
        self.download_dir = work_dir / "downloads"
        self.capture_dir = work_dir / "captures"
        self.home_dir = work_dir / "home"
        self.telegym_port = unused_local_port()
        self.metrics_port = unused_local_port()
        while self.metrics_port == self.telegym_port:
            self.metrics_port = unused_local_port()
        self.telegym = Telegym(
            base_url=f"http://127.0.0.1:{self.telegym_port}", token=FAKE_TOKEN
        )
        self.ffprobe = Ffprobe(self.args.ffprobe)
        self.processes = ProcessGroup(work_dir)
        self.lolek = Lolek(
            executable=args.lolek,
            telegram_base_url=self.telegym.base_url,
            bot_token=FAKE_TOKEN,
            download_dir=self.download_dir,
            home_dir=self.home_dir,
            metrics_port=self.metrics_port,
            profile=args.profile,
            processes=self.processes,
        )
        self.last_service_start: dict[Service, float] = {}
        self.last_live_start: float | None = None
        self.rate_limited_services: set[Service] = set()

    def start(self) -> None:
        """Start and await the Telegym and Lolek processes."""
        self.capture_dir.mkdir()
        telegym_env = clean_environment("TELEGYM_")
        telegym_env.update(
            {
                "TELEGYM_MOCK_LISTEN": f"127.0.0.1:{self.telegym_port}",
                "TELEGYM_MOCK_METRICS_LISTEN": "",
                "TELEGYM_MOCK_FILE_STORE_MAX_BYTES": str(TELEGYM_FILE_STORE_BYTES),
                "TELEGYM_MOCK_QUIET": "true",
            }
        )
        self.processes.start("telegym", [str(self.args.telegym)], telegym_env)
        self.processes.wait_until(
            "Telegym health",
            self.telegym.healthy,
            30,
        )

        self.lolek.start()
        self.processes.wait_until(
            "Lolek polling registration",
            self.telegym.polling_registered,
            60,
        )

    def stop(self) -> None:
        """Stop every child process owned by the harness."""
        self.processes.stop()

    def throttle(self, case: CorpusCase) -> None:
        """Apply global and service-local delays before a live injection."""
        now = time.monotonic()
        not_before = now
        if self.last_live_start is not None:
            not_before = max(not_before, self.last_live_start + self.args.global_delay)
        last_service = self.last_service_start.get(case.service)
        if last_service is not None:
            delay = self.args.service_delay + deterministic_jitter(
                case.id, self.args.jitter
            )
            not_before = max(not_before, last_service + delay)
        remaining = not_before - now
        if remaining > 0:
            print(f"  throttling {remaining:.1f}s", flush=True)
            time.sleep(remaining)
        started = time.monotonic()
        self.last_live_start = started
        self.last_service_start[case.service] = started

    def run_case(
        self, case: CorpusCase, expectation: Expectation, chat_id: int
    ) -> tuple[Observation, Verdict]:
        """Run one first-pass request and optional cache replay."""
        case_log = ""
        observed = None
        try:
            self.telegym.clear()
            self.lolek.reset_cache(case.url)
            self.lolek.read_new_log()
            before = self.lolek.snapshot()
            self.telegym.inject_message(chat_id, case.url)
            result = self.lolek.wait_for_terminal(before, self.args.case_timeout)
            self.lolek.wait_for_idle()
            media = self.telegym.media(chat_id)
            case_log = self.lolek.read_new_log()
            observed = Observation(
                terminal_result=result,
                media_count=len(media),
                media_kinds=tuple(sorted(item.kind for item in media)),
                file_ids=tuple(sorted(item.file_id for item in media)),
                rate_limited=bool(RATE_LIMIT_PATTERN.search(case_log)),
                failure_reason=classify_failure_reason(result, case_log),
            )

            verdict = expectation_verdict(expectation, observed)
            captures = ()
            if result == TERMINAL_OK:
                after = self.lolek.snapshot()
                if after.cache_increment_since(before, CACHE_NEW_FILE) != 1:
                    raise CaseMismatch(
                        "first pass did not record a new_file cache lookup"
                    )
                captures = self.inspect_captures(media)
                self.lolek.assert_cached(case.url, captures)
                if not self.args.no_cache_replay:
                    self.assert_cache_replay(case, chat_id, observed)
            observed = dataclasses.replace(observed, captures=captures)
            return observed, verdict
        except (CaseMismatch, HarnessError) as error:
            if not case_log:
                case_log = self.lolek.read_new_log()
            error.case_log = case_log
            if observed is not None:
                error.observed = observed
            if RATE_LIMIT_PATTERN.search(case_log):
                self.rate_limited_services.add(case.service)
            raise
        finally:
            try:
                self.telegym.clear()
            finally:
                self.lolek.reset_cache(case.url)

    def inspect_captures(
        self, kinds_and_ids: Sequence[MediaReference]
    ) -> tuple[Capture, ...]:
        """Download, hash, and ffprobe every fresh multipart capture."""
        captures = []
        for index, media in enumerate(kinds_and_ids, start=1):
            # Telegram filenames can exceed filesystem component limits.
            target = self.capture_dir / f"capture-{index}"
            downloaded = self.telegym.download_file(media.file_id, target)
            if downloaded.size <= 0 or downloaded.size > MAX_TELEGRAM_FILE_BYTES:
                raise CaseMismatch(
                    f"captured {downloaded.filename!r} has invalid size "
                    f"{downloaded.size}"
                )
            media_info = self.ffprobe.inspect(target)
            self.assert_media_info(media.kind, downloaded.filename, media_info)
            captures.append(
                Capture(
                    kind=media.kind,
                    file_id=media.file_id,
                    filename=downloaded.filename,
                    extension=Path(downloaded.filename).suffix.lower(),
                    size=downloaded.size,
                    sha256=downloaded.sha256,
                )
            )
            target.unlink()
        return tuple(captures)

    def assert_media_info(
        self, kind: TelegramMediaKind, filename: str, media_info: MediaInfo
    ) -> None:
        """Assert basic Telegram media integrity and video compatibility."""
        if not media_info.video_streams:
            raise CaseMismatch(f"captured {filename!r} has no video/image stream")
        first = media_info.video_streams[0]
        if first.width <= 0 or first.height <= 0:
            raise CaseMismatch(f"captured {filename!r} has invalid dimensions")
        if kind is TelegramMediaKind.VIDEO:
            if first.codec != H264_CODEC:
                raise CaseMismatch(
                    f"video {filename!r} codec is {first.codec!r}, expected 'h264'"
                )
            if MP4_CONTAINER not in media_info.containers:
                raise CaseMismatch(
                    f"video {filename!r} containers are "
                    f"{sorted(media_info.containers)!r}, expected MP4"
                )

    def assert_cache_replay(
        self, case: CorpusCase, chat_id: int, first_observed: Observation
    ) -> None:
        """Inject the URL again and require a Telegym-ID-only cache hit."""
        self.telegym.clear_messages()
        file_stats_before = self.telegym.file_store_stats()
        before = self.lolek.snapshot()
        self.telegym.inject_message(chat_id, case.url)
        terminal = self.lolek.wait_for_terminal(before, self.args.case_timeout)
        self.lolek.wait_for_idle()
        if terminal != TERMINAL_OK:
            raise CaseMismatch(
                f"cache replay terminal result is {terminal!r}, expected 'ok'"
            )
        replay_media = self.telegym.media(chat_id)
        replay_ids = tuple(sorted(media.file_id for media in replay_media))
        replay_kinds = tuple(sorted(media.kind for media in replay_media))
        if (
            replay_ids != first_observed.file_ids
            or replay_kinds != first_observed.media_kinds
        ):
            raise CaseMismatch(
                f"cache replay media {(replay_kinds, replay_ids)!r} differs from first pass"
            )
        file_stats_after = self.telegym.file_store_stats()
        if file_stats_after != file_stats_before:
            raise CaseMismatch(
                f"cache replay changed Telegym file store: {file_stats_before!r} -> {file_stats_after!r}"
            )
        after = self.lolek.snapshot()
        if after.cache_increment_since(before, CACHE_READY_TO_TELEGRAM) != 1:
            raise CaseMismatch("cache replay did not record a ready_to_telegram lookup")
