"""Harness-facing interface to one isolated Lolek process."""

from __future__ import annotations

import dataclasses
import os
from collections.abc import Sequence
from pathlib import Path

from lolek_corpus.cache import LolekCache
from lolek_corpus.metrics import LolekMetrics, MetricSnapshot
from lolek_corpus.model import Capture, HarnessError, Profile, TerminalResult
from lolek_corpus.processes import ManagedProcess, ProcessGroup, clean_environment


@dataclasses.dataclass
class Lolek:
    """Compose Lolek's process, configuration, metrics, logs, and cache."""

    executable: Path
    telegram_base_url: str
    bot_token: str
    download_dir: Path
    home_dir: Path
    metrics_port: int
    profile: Profile
    processes: ProcessGroup
    _process: ManagedProcess | None = dataclasses.field(default=None, init=False)
    _metrics: LolekMetrics = dataclasses.field(init=False)
    _cache: LolekCache = dataclasses.field(init=False)

    def __post_init__(self) -> None:
        """Construct Lolek adapters from the isolated runtime paths."""
        self._metrics = LolekMetrics(f"http://127.0.0.1:{self.metrics_port}/metrics")
        self._cache = LolekCache(self.download_dir)

    def start(self) -> None:
        """Start Lolek and wait for its metrics endpoint."""
        if self._process is not None:
            raise HarnessError("Lolek is already started")
        self.download_dir.mkdir()
        self.home_dir.mkdir()
        self._process = self.processes.start(
            "lolek", [str(self.executable), "start"], self.environment()
        )
        self.processes.wait_until("Lolek metrics", self._metrics.snapshot, 60)

    def environment(self) -> dict[str, str]:
        """Build the isolated process environment for this Lolek profile."""
        environment = clean_environment("LOLEK_")
        environment.update(
            {
                "HOME": str(self.home_dir),
                "XDG_CACHE_HOME": str(self.home_dir / ".cache"),
                "XDG_CONFIG_HOME": str(self.home_dir / ".config"),
                "RELEASE_COOKIE": "lolek_live_corpus",
                "RELEASE_NODE": f"lolek_live_corpus_{os.getpid()}",
                "LOLEK_BOT_TOKEN": self.bot_token,
                "LOLEK_TELEGRAM_BASE_URL": self.telegram_base_url,
                "LOLEK_DOWNLOAD_DIR_PATH": str(self.download_dir),
                "LOLEK_METRICS_ENABLED": "true",
                "LOLEK_METRICS_LISTEN_ADDRESS": "127.0.0.1",
                "LOLEK_METRICS_PORT": str(self.metrics_port),
                "LOLEK_GALLERY_DOWNLOAD_ENABLED": (
                    "true" if self.profile is Profile.GALLERY else "false"
                ),
                # A live corpus sweep must not multiply requests to a failing service.
                "LOLEK_MAX_DOWNLOAD_TRIES": "1",
            }
        )
        return environment

    def snapshot(self) -> MetricSnapshot:
        """Return one typed snapshot of observable Lolek behavior."""
        return self._metrics.snapshot()

    def wait_for_terminal(
        self, before: MetricSnapshot, timeout: float
    ) -> TerminalResult:
        """Wait for one new terminal message result."""

        def completed() -> MetricSnapshot | None:
            after = self.snapshot()
            return after if after.message_total > before.message_total else None

        after = self.processes.wait_until(
            "one terminal message result", completed, timeout
        )
        return after.terminal_result_since(before)

    def wait_for_idle(self) -> None:
        """Wait until no Lolek processing task is active or queued."""
        self.processes.wait_until(
            "Lolek processing idle", lambda: self.snapshot().idle, 30
        )

    def read_new_log(self) -> str:
        """Return log data written since the previous read."""
        if self._process is None:
            raise HarnessError("Lolek is not started")
        return self._process.read_new_log()

    def reset_cache(self, url: str) -> None:
        """Remove one URL's complete cache entry."""
        self._cache.reset(url)

    def assert_cached(self, url: str, captures: Sequence[Capture]) -> None:
        """Require one URL's ready manifest to match fresh captures."""
        self._cache.assert_matches(url, captures)
