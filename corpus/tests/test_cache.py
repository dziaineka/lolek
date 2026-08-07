"""Tests for typed Lolek cache access."""

import json
import tempfile
from pathlib import Path

from support import CorpusTestCase

from lolek_corpus import cache


class CacheTest(CorpusTestCase):
    """Cover URL paths and ready-media manifest decoding."""

    def test_cache_path_matches_lolek_encoding(self):
        self.assertEqual(
            cache.LolekCache(Path("cache")).path_for("HTTPS://EXAMPLE.COM/A").name,
            "aHR0cHM6Ly9leGFtcGxlLmNvbS9h",
        )

    def test_lolek_cache_returns_typed_ready_media(self):
        url = "https://example.test/video"
        with tempfile.TemporaryDirectory() as directory:
            lolek_cache = cache.LolekCache(Path(directory))
            ready_directory = lolek_cache.path_for(url) / cache.READY_DIRECTORY
            ready_directory.mkdir(parents=True)
            (ready_directory / cache.MEDIA_MANIFEST).write_text(
                json.dumps([{"file_id": "telegram-id", "ext": ".mp4"}]),
                encoding="utf-8",
            )

            ready_media = lolek_cache.ready_media(url)

        self.assertEqual(
            ready_media,
            (cache.ReadyMedia("telegram-id", ".mp4"),),
        )
