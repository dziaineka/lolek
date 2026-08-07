"""Supervise child processes used by the live corpus harness."""

from __future__ import annotations

import contextlib
import dataclasses
import os
import signal
import subprocess
import time
import urllib.error
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path

from lolek_corpus.model import HarnessError


def clean_environment(prefix: str) -> dict[str, str]:
    """Remove ambient service configuration while preserving process state."""
    return {
        key: value for key, value in os.environ.items() if not key.startswith(prefix)
    }


@dataclasses.dataclass
class ManagedProcess:
    """A supervised child process and its incremental log reader."""

    name: str
    process: subprocess.Popen[bytes]
    log_path: Path
    log_offset: int = 0

    def read_new_log(self) -> str:
        """Return log data written since the previous call."""
        try:
            with self.log_path.open(encoding="utf-8", errors="replace") as log_file:
                log_file.seek(self.log_offset)
                content = log_file.read()
                self.log_offset = log_file.tell()
                return content
        except FileNotFoundError:
            return ""

    def assert_running(self, description: str) -> None:
        """Raise if the process exited while awaiting an operation."""
        return_code = self.process.poll()
        if return_code is not None:
            raise HarnessError(
                f"{self.name} exited with status {return_code} "
                f"while waiting for {description}"
            )


@dataclasses.dataclass
class ProcessGroup:
    """Own the lifecycle of every child process in one corpus run."""

    work_dir: Path
    _managed: list[ManagedProcess] = dataclasses.field(default_factory=list, init=False)

    def start(
        self, name: str, command: Sequence[str], environment: Mapping[str, str]
    ) -> ManagedProcess:
        """Start one process in its own group with a dedicated log."""
        log_path = self.work_dir / f"{name}.log"
        log_handle = log_path.open("wb")
        try:
            process = subprocess.Popen(
                command,
                cwd=self.work_dir,
                env=environment,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        finally:
            log_handle.close()
        child = ManagedProcess(name, process, log_path)
        self._managed.append(child)
        return child

    def wait_until[PredicateResult](
        self,
        description: str,
        predicate: Callable[[], PredicateResult | None],
        timeout: float,
    ) -> PredicateResult:
        """Poll a predicate while ensuring every child remains alive."""
        deadline = time.monotonic() + timeout
        last_error = None
        while time.monotonic() < deadline:
            for child in self._managed:
                child.assert_running(description)
            try:
                value = predicate()
                if value:
                    return value
            except (
                ConnectionError,
                OSError,
                urllib.error.URLError,
                HarnessError,
            ) as error:
                last_error = error
            time.sleep(0.25)
        suffix = f": {last_error}" if last_error else ""
        raise HarnessError(f"timed out waiting for {description}{suffix}")

    def stop(self) -> None:
        """Terminate all child process groups, escalating after a grace period."""
        for child in reversed(self._managed):
            if child.process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.process.pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        for child in reversed(self._managed):
            remaining = max(deadline - time.monotonic(), 0)
            try:
                child.process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.process.pid, signal.SIGKILL)
                child.process.wait()
