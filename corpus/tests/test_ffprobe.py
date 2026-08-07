"""Tests for typed ffprobe media inspection."""

import json
import subprocess
from pathlib import Path
from unittest import mock

from support import CorpusTestCase

from lolek_corpus import ffprobe


class FfprobeTest(CorpusTestCase):
    """Cover ffprobe response narrowing."""

    def test_ffprobe_returns_typed_media_info(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "streams": [
                        {
                            "codec_type": "video",
                            "codec_name": "h264",
                            "width": 1920,
                            "height": 1080,
                        }
                    ],
                    "format": {"format_name": "mov,mp4,m4a"},
                }
            ),
            stderr="",
        )
        with mock.patch.object(ffprobe.subprocess, "run", return_value=completed):
            media_info = ffprobe.Ffprobe(Path("ffprobe")).inspect(Path("capture"))

        self.assertEqual(
            media_info.video_streams,
            (ffprobe.VideoStream(ffprobe.H264_CODEC, 1920, 1080),),
        )
        self.assertIn(ffprobe.MP4_CONTAINER, media_info.containers)
