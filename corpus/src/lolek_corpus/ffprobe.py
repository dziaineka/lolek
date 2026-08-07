"""Typed media inspection through ffprobe."""

from __future__ import annotations

import dataclasses
import json
import subprocess
from pathlib import Path
from typing import cast

from lolek_corpus.json_data import JsonObject
from lolek_corpus.model import CaseMismatch


class CodecName(str):
    """An extensible codec name reported by ffprobe."""


class ContainerName(str):
    """An extensible container name reported by ffprobe."""


H264_CODEC = CodecName("h264")
MP4_CONTAINER = ContainerName("mp4")


@dataclasses.dataclass(frozen=True)
class VideoStream:
    """The video properties relevant to Telegram compatibility."""

    codec: CodecName | None
    width: int
    height: int


@dataclasses.dataclass(frozen=True)
class MediaInfo:
    """Typed media-container and video-stream information."""

    containers: frozenset[ContainerName]
    video_streams: tuple[VideoStream, ...]


@dataclasses.dataclass(frozen=True)
class Ffprobe:
    """Inspect media through one ffprobe executable."""

    executable: Path

    def inspect(self, path: Path) -> MediaInfo:
        """Run ffprobe and return the relevant typed media information."""
        completed = subprocess.run(
            [
                str(self.executable),
                "-v",
                "error",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if completed.returncode != 0:
            raise CaseMismatch(
                f"ffprobe rejected {path.name!r}: {completed.stderr.strip()}"
            )
        try:
            decoded = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise CaseMismatch(
                f"ffprobe returned invalid JSON for {path.name!r}"
            ) from error
        return parse_media_info(decoded, path.name)


def parse_media_info(decoded: object, filename: str) -> MediaInfo:
    """Validate and narrow one decoded ffprobe response."""
    if not isinstance(decoded, dict):
        raise CaseMismatch(f"ffprobe returned a non-object for {filename!r}")
    decoded = cast(JsonObject, decoded)
    streams = decoded.get("streams", [])
    if not isinstance(streams, list):
        raise CaseMismatch(f"ffprobe returned malformed streams for {filename!r}")
    videos = _parse_video_streams(streams, filename)
    raw_format = decoded.get("format", {})
    if not isinstance(raw_format, dict):
        raise CaseMismatch(f"ffprobe returned malformed format for {filename!r}")
    format_name = raw_format.get("format_name", "")
    if not isinstance(format_name, str):
        raise CaseMismatch(f"ffprobe returned malformed format name for {filename!r}")
    return MediaInfo(
        containers=frozenset(
            ContainerName(name) for name in format_name.split(",") if name
        ),
        video_streams=videos,
    )


def _parse_video_streams(
    streams: list[object], filename: str
) -> tuple[VideoStream, ...]:
    """Validate the stream collection and retain typed video streams."""
    videos = []
    for stream in streams:
        if not isinstance(stream, dict):
            raise CaseMismatch(f"ffprobe returned malformed streams for {filename!r}")
        stream = cast(JsonObject, stream)
        if stream.get("codec_type") == "video":
            videos.append(_parse_video_stream(stream, filename))
    return tuple(videos)


def _parse_video_stream(raw: JsonObject, filename: str) -> VideoStream:
    """Parse the relevant fields from one ffprobe video stream."""
    codec = raw.get("codec_name")
    if codec is not None and not isinstance(codec, str):
        raise CaseMismatch(f"ffprobe returned malformed codec for {filename!r}")
    width = _dimension(raw.get("width"), "width", filename)
    height = _dimension(raw.get("height"), "height", filename)
    return VideoStream(
        codec=CodecName(codec) if codec is not None else None,
        width=width,
        height=height,
    )


def _dimension(raw: object, field: str, filename: str) -> int:
    """Validate one integer stream dimension."""
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise CaseMismatch(f"ffprobe returned malformed video {field} for {filename!r}")
    return raw
