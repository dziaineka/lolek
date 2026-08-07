"""Own the host lock and temporary files for one live corpus run."""

from __future__ import annotations

import dataclasses
import fcntl
import shutil
import tempfile
from pathlib import Path
from types import TracebackType
from typing import Self, TextIO

from lolek_corpus.model import HarnessError


@dataclasses.dataclass
class RunWorkspace:
    """Serialize live runs and clean their temporary working directory."""

    keep: bool
    temporary_root: Path | None = None
    lock_path: Path | None = None
    _path: Path | None = dataclasses.field(default=None, init=False)
    _lock_file: TextIO | None = dataclasses.field(default=None, init=False)

    @property
    def path(self) -> Path:
        """Return the active temporary directory."""
        if self._path is None:
            raise HarnessError("live corpus workspace is not active")
        return self._path

    def __enter__(self) -> Self:
        """Acquire the host lock and create an isolated temporary directory."""
        lock_path = self.lock_path or (
            Path(tempfile.gettempdir()) / "lolek-live-corpus.lock"
        )
        self._lock_file = lock_path.open("w")
        try:
            fcntl.flock(self._lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self._lock_file.close()
            self._lock_file = None
            raise HarnessError("another live corpus run holds the host lock") from error
        try:
            self._path = Path(
                tempfile.mkdtemp(prefix="lolek-live-corpus-", dir=self.temporary_root)
            )
        except BaseException:
            self._lock_file.close()
            self._lock_file = None
            raise
        return self

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Remove unretained files and release the host lock."""
        try:
            if self._path is not None and not self.keep:
                shutil.rmtree(self._path)
        except OSError as error:
            if exception_type is None:
                raise HarnessError(
                    f"could not remove live corpus workspace {self._path}: {error}"
                ) from error
        finally:
            if self._lock_file is not None:
                self._lock_file.close()
                self._lock_file = None
            self._path = None
