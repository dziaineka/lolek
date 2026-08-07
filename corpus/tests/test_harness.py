"""Tests for live case capture orchestration."""

import tempfile
from pathlib import Path
from unittest import mock

from support import CorpusTestCase

from lolek_corpus import ffprobe, harness, model, telegym


class HarnessTest(CorpusTestCase):
    """Cover harness configuration and bounded capture files."""

    def test_harness_enables_gallery_only_for_gallery_profile(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(harness, "unused_local_port", side_effect=[1, 2, 3, 4]),
        ):
            path = Path(directory)
            no_gallery = harness.LiveCorpusHarness(self.runner_config(), path)
            gallery = harness.LiveCorpusHarness(
                self.runner_config("--profile", "gallery"), path
            )

        self.assertEqual(
            no_gallery.lolek.environment()["LOLEK_GALLERY_DOWNLOAD_ENABLED"],
            "false",
        )
        self.assertEqual(
            gallery.lolek.environment()["LOLEK_GALLERY_DOWNLOAD_ENABLED"], "true"
        )

    def test_capture_uses_bounded_temporary_filename(self):
        filename = f"{'a' * 260}.mp4"
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.headers.get_filename.return_value = filename
        response.read.side_effect = [b"media", b""]

        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(harness, "unused_local_port", side_effect=[1, 2]),
        ):
            instance = harness.LiveCorpusHarness(self.runner_config(), Path(directory))
            instance.capture_dir.mkdir()
            with (
                mock.patch.object(
                    telegym.urllib.request, "urlopen", return_value=response
                ),
                mock.patch.object(
                    ffprobe.Ffprobe,
                    "inspect",
                    return_value=ffprobe.MediaInfo(frozenset(), ()),
                ) as probe,
                mock.patch.object(instance, "assert_media_info"),
            ):
                captures = instance.inspect_captures(
                    [model.MediaReference(model.TelegramMediaKind.VIDEO, "file-id")]
                )

        probe.assert_called_once_with(instance.capture_dir / "capture-1")
        self.assertEqual(captures[0].filename, filename)
        self.assertEqual(captures[0].extension, ".mp4")
