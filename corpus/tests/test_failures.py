"""Tests for stable downloader failure classification."""

from support import CorpusTestCase

from lolek_corpus import failures, model


class FailureClassificationTest(CorpusTestCase):
    """Cover volatile diagnostics mapped into report reasons."""

    def test_failure_reasons_normalize_downloader_diagnostics(self):
        cases = [
            (
                "error",
                "This video is only available for registered users",
                "authentication_required",
            ),
            (
                "error",
                "You need to log in to access this content",
                "authentication_required",
            ),
            (
                "error",
                "Your IP address is blocked from accessing this post",
                "access_blocked",
            ),
            (
                "error",
                "ERROR: Unsupported URL: https://www.tiktok.com/?_r=1",
                "stale_redirect",
            ),
            (
                "error",
                "Cannot parse data; please report this issue",
                "extractor_error",
            ),
            ("error", "HTTP Error 500: Domain Not Found", "stale_media"),
            ("error", "HTTP Error 404: Not Found", "stale_media"),
            ("error", "Tweet unavailable ('Suspended')", "stale_media"),
            (
                "error",
                'Finished download; result=error:"File not found"',
                "download_output_missing",
            ),
            (
                "no_usable_media_files",
                "Omitting media: :too_big_media",
                "default_media_limit",
            ),
            ("no_video_formats", "No video formats found", "no_video_formats"),
            ("error", "No video formats found", "no_video_formats"),
            (
                "error",
                "ERROR: Unsupported URL: https://example.test/article",
                "unsupported_media",
            ),
        ]
        for terminal_result, case_log, expected in cases:
            with self.subTest(expected):
                self.assertEqual(
                    failures.classify_failure_reason(
                        model.TerminalResult(terminal_result), case_log
                    ),
                    model.FailureReason(expected),
                )

        self.assertIsNone(
            failures.classify_failure_reason(model.TERMINAL_OK, "warning")
        )
        self.assertEqual(
            failures.classify_failure_reason(model.TERMINAL_ERROR, "other failure"),
            model.FailureReason.UNCLASSIFIED,
        )
