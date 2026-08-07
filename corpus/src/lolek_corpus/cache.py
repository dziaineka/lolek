"""Typed access to Lolek's on-disk media cache."""

from __future__ import annotations

import base64
import collections
import dataclasses
import json
import shutil
from collections.abc import Sequence
from pathlib import Path
from typing import cast

from lolek_corpus.json_data import JsonObject
from lolek_corpus.model import Capture, CaseMismatch, HarnessError

READY_DIRECTORY = "ready_to_telegram"
MEDIA_MANIFEST = "media_manifest.json"


@dataclasses.dataclass(frozen=True)
class ReadyMedia:
    """One Telegram file identifier persisted in a ready cache manifest."""

    file_id: str
    extension: str


@dataclasses.dataclass(frozen=True)
class LolekCache:
    """Own the cache layout used by one isolated Lolek process."""

    root: Path

    def reset(self, url: str) -> None:
        """Remove the complete cache entry owned by one corpus URL."""
        try:
            shutil.rmtree(self.path_for(url))
        except FileNotFoundError:
            pass
        except OSError as error:
            raise HarnessError(
                f"could not reset Lolek cache for {url!r}: {error}"
            ) from error

    def ready_media(self, url: str) -> tuple[ReadyMedia, ...]:
        """Load and validate the ready-media manifest for one URL."""
        path = self.path_for(url) / READY_DIRECTORY / MEDIA_MANIFEST
        try:
            decoded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise CaseMismatch(
                f"ready media manifest is unavailable: {error}"
            ) from error
        if not isinstance(decoded, list):
            raise CaseMismatch("ready media manifest must be a list")
        return tuple(
            _parse_ready_media(entry, index)
            for index, entry in enumerate(decoded, start=1)
        )

    def assert_matches(self, url: str, captures: Sequence[Capture]) -> None:
        """Require the ready manifest to contain the freshly captured media."""
        expected = collections.Counter(
            ReadyMedia(capture.file_id, capture.extension) for capture in captures
        )
        actual = collections.Counter(self.ready_media(url))
        if actual != expected:
            raise CaseMismatch(
                f"ready media manifest {dict(actual)!r}, expected {dict(expected)!r}"
            )

    def path_for(self, url: str) -> Path:
        """Return the cache entry path corresponding to one URL."""
        encoded = base64.b64encode(url.lower().encode("utf-8"))
        return self.root / encoded.decode("ascii").rstrip("=")


def _parse_ready_media(raw: object, index: int) -> ReadyMedia:
    """Validate one ready-media manifest entry."""
    if not isinstance(raw, dict):
        raise CaseMismatch(f"ready media manifest entry {index} must be an object")
    raw = cast(JsonObject, raw)
    file_id = raw.get("file_id")
    extension = raw.get("ext")
    if not isinstance(file_id, str) or not file_id:
        raise CaseMismatch(f"ready media manifest entry {index} has an invalid file ID")
    if not isinstance(extension, str):
        raise CaseMismatch(
            f"ready media manifest entry {index} has an invalid extension"
        )
    return ReadyMedia(file_id, extension)
