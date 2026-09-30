"""Typed access to the Telegym debug API used by live corpus tests."""

from __future__ import annotations

import dataclasses
import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from lolek_corpus.json_data import (
    JsonObject,
    require_json_object,
    require_json_object_list,
    require_non_empty_string,
)
from lolek_corpus.model import (
    CaseMismatch,
    HarnessError,
    MediaReference,
    TelegramMediaKind,
)


@dataclasses.dataclass(frozen=True)
class FileStoreStats:
    """The observable size of Telegym's retained multipart file store."""

    count: int
    total_bytes: int


@dataclasses.dataclass(frozen=True)
class DownloadedFile:
    """Metadata collected while downloading one retained Telegym file."""

    filename: str
    size: int
    sha256: str


def message_media(message: JsonObject) -> tuple[MediaReference, ...]:
    """Return every Telegram media kind and file ID from a Telegym message.

    A classic message carries one media object; a rich message carries its
    media in blocks, collages included, in the order they are shown.
    """
    if message.get("rich_message") is not None:
        rich_message = require_json_object(
            message["rich_message"], "Telegym rich message"
        )
        blocks = require_json_object_list(
            rich_message.get("blocks", []), "Telegym rich message blocks"
        )
        media = tuple(
            reference for block in blocks for reference in _block_media(block)
        )
        if not media:
            raise CaseMismatch(f"rich Telegym message without media: {message!r}")
        return media
    media = _media_object(message, "Telegym message")
    if media is None:
        raise CaseMismatch(f"unexpected non-media Telegym message: {message!r}")
    return (media,)


def _block_media(block: JsonObject) -> tuple[MediaReference, ...]:
    """Return the media of one rich block, descending into collages."""
    if block.get("type") == "collage":
        nested = require_json_object_list(
            block.get("blocks", []), "Telegym rich collage blocks"
        )
        return tuple(reference for item in nested for reference in _block_media(item))
    media = _media_object(block, "Telegym rich block")
    return () if media is None else (media,)


def _media_object(holder: JsonObject, label: str) -> MediaReference | None:
    """Return the media stored on a message or a rich media block, if any."""
    for field, kind in (
        ("video", TelegramMediaKind.VIDEO),
        ("animation", TelegramMediaKind.ANIMATION),
        ("document", TelegramMediaKind.DOCUMENT),
    ):
        if field in holder and holder[field] is not None:
            media = require_json_object(holder[field], f"{label} {field}")
            return MediaReference(
                kind,
                require_non_empty_string(
                    media.get("file_id"), f"{label} {field}.file_id"
                ),
            )
    if "photo" in holder and holder["photo"] is not None:
        photos = require_json_object_list(holder["photo"], f"{label} photo")
        if not photos:
            raise HarnessError(f"{label} photo must not be empty")
        return MediaReference(
            TelegramMediaKind.PHOTO,
            require_non_empty_string(
                photos[-1].get("file_id"), f"{label} photo file_id"
            ),
        )
    return None


@dataclasses.dataclass(frozen=True)
class Telegym:
    """Expose the Telegym operations required by the live corpus harness."""

    base_url: str
    token: str

    def healthy(self) -> bool:
        """Return whether Telegym reports itself healthy."""
        return self._json("/health", timeout=2).get("status") == "ok"

    def polling_registered(self) -> bool:
        """Return whether the corpus bot registered for polling."""
        response = self._json("/debug/bots", timeout=2)
        bots = require_json_object_list(response.get("bots", []), "Telegym bots")
        return any(bot.get("token_full") == self.token for bot in bots)

    def clear(self) -> None:
        """Clear outbound messages and every retained multipart file."""
        self.clear_messages()
        cleared = self._json("/debug/files", method="DELETE")
        stats = self.file_store_stats()
        if stats != FileStoreStats(count=0, total_bytes=0):
            raise HarnessError(
                "Telegym file store is not empty after cleanup: "
                f"{stats!r}; clear={cleared!r}"
            )

    def clear_messages(self) -> None:
        """Clear outbound messages for the corpus bot."""
        token = urllib.parse.quote(self.token, safe="")
        self._json(f"/debug/messages/{token}/clear", method="POST")

    def inject_message(self, chat_id: int, text: str) -> None:
        """Inject one text message as a polling update."""
        response = self._json(
            "/debug/inject/update",
            method="POST",
            payload={
                "token": self.token,
                "chat_id": chat_id,
                "username": "live_corpus",
                "first_name": "Live Corpus",
                "text": text,
            },
        )
        if not response.get("ok") or response.get("delivery_method") != "polling":
            raise HarnessError(f"Telegym did not inject by polling: {response!r}")

    def media(self, chat_id: int) -> tuple[MediaReference, ...]:
        """Return typed media references from one test chat's messages."""
        token = urllib.parse.quote(self.token, safe="")
        query = urllib.parse.urlencode({"chat_id": chat_id})
        response = self._json(f"/debug/messages/{token}?{query}")
        messages = require_json_object_list(
            response.get("messages", []), "Telegym messages"
        )
        return tuple(
            reference for message in messages for reference in message_media(message)
        )

    def file_store_stats(self) -> FileStoreStats:
        """Return the retained multipart file count and total size."""
        response = self._json("/debug/files")
        count = response.get("count")
        total_bytes = response.get("total_bytes")
        if (
            isinstance(count, bool)
            or not isinstance(count, int)
            or count < 0
            or isinstance(total_bytes, bool)
            or not isinstance(total_bytes, int)
            or total_bytes < 0
        ):
            raise HarnessError("Telegym file store response is malformed")
        return FileStoreStats(count=count, total_bytes=total_bytes)

    def download_file(self, file_id: str, target: Path) -> DownloadedFile:
        """Download one retained multipart file to a runner-owned path."""
        encoded_id = urllib.parse.quote(file_id, safe="")
        request = urllib.request.Request(self._url(f"/debug/files/{encoded_id}"))
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                filename = response.headers.get_filename() or target.name
                digest = hashlib.sha256()
                size = 0
                with target.open("wb") as output:
                    while chunk := response.read(64 * 1024):
                        output.write(chunk)
                        digest.update(chunk)
                        size += len(chunk)
        except urllib.error.HTTPError as error:
            raise CaseMismatch(
                f"Telegym capture {file_id!r} is unavailable: HTTP {error.code}"
            ) from error
        return DownloadedFile(
            filename=filename,
            size=size,
            sha256=digest.hexdigest(),
        )

    def _json(
        self,
        path: str,
        method: str = "GET",
        payload: JsonObject | None = None,
        timeout: float = 10,
    ) -> JsonObject:
        """Issue one JSON request to the Telegym API."""
        url = self._url(path)
        body = None
        headers = {}
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                decoded = json.load(response)
                return require_json_object(decoded, f"{method} {url} response")
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise HarnessError(
                f"{method} {url} returned HTTP {error.code}: {detail}"
            ) from error

    def _url(self, path: str) -> str:
        """Return one absolute Telegym API URL."""
        return f"{self.base_url.rstrip('/')}/{path.lstrip('/')}"
