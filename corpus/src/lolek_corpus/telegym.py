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


_MEDIA_BLOCKS = (
    ("photo", TelegramMediaKind.PHOTO),
    ("video", TelegramMediaKind.VIDEO),
    ("animation", TelegramMediaKind.ANIMATION),
    ("document", TelegramMediaKind.DOCUMENT),
)


def _block_media(block: JsonObject) -> list[MediaReference]:
    """Return the media of one rich message block and its nested blocks."""
    block_type = block.get("type")
    for field, kind in _MEDIA_BLOCKS:
        if block_type != field:
            continue
        if kind is TelegramMediaKind.PHOTO:
            sizes = require_json_object_list(block.get("photo"), "Telegym photo block")
            if not sizes:
                raise HarnessError("Telegym photo block must not be empty")
            media = sizes[-1]
        else:
            media = require_json_object(block.get(field), f"Telegym {field} block")
        file_id = require_non_empty_string(
            media.get("file_id"), f"Telegym {field} block file_id"
        )
        # Telegym returns the URL as the file ID of media sent by URL, like the
        # images of a quoted post. Those are not uploads of Lolek.
        if file_id.startswith(("http://", "https://")):
            return []
        return [MediaReference(kind, file_id)]
    nested = block.get("blocks")
    if nested is None:
        return []
    return [
        media
        for child in require_json_object_list(nested, "Telegym nested blocks")
        for media in _block_media(child)
    ]


def message_media(message: JsonObject) -> tuple[MediaReference, ...]:
    """Return the uploaded media kinds and file IDs of one Telegym rich message."""
    rich_message = message.get("rich_message")
    if rich_message is None:
        raise CaseMismatch(f"unexpected non-rich Telegym message: {message!r}")
    blocks = require_json_object_list(
        require_json_object(rich_message, "Telegym rich message").get("blocks"),
        "Telegym rich message blocks",
    )
    media = tuple(item for block in blocks for item in _block_media(block))
    if not media:
        raise CaseMismatch(f"unexpected non-media Telegym message: {message!r}")
    return media


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
        # A polling bot gets the update from getUpdates, so Telegym queues it.
        if response.get("ok") is not True or response.get("queued") is not True:
            raise HarnessError(f"Telegym did not queue the update: {response!r}")

    def media(self, chat_id: int) -> tuple[MediaReference, ...]:
        """Return typed media references from one test chat's messages."""
        token = urllib.parse.quote(self.token, safe="")
        query = urllib.parse.urlencode({"chat_id": chat_id})
        response = self._json(f"/debug/messages/{token}?{query}")
        messages = require_json_object_list(
            response.get("messages", []), "Telegym messages"
        )
        return tuple(item for message in messages for item in message_media(message))

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
