"""Tests for corpus and expectation file decoding."""

import json
import tempfile
from pathlib import Path

from support import CorpusTestCase

from lolek_corpus import config, corpus_data, model, policy


class CorpusDataTest(CorpusTestCase):
    """Cover validated dynamic input boundaries."""

    def test_load_corpus_returns_validated_cases(self):
        contents = json.dumps(
            {
                "id": "case",
                "service": "tiktok",
                "sources": ["yt-dlp"],
                "kinds": ["video"],
                "url": "https://example.test/video",
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "corpus.jsonl"
            path.write_text(contents, encoding="utf-8")
            cases = corpus_data.load_corpus(path)

        self.assertEqual(cases[0].service, model.Service.TIKTOK)
        self.assertEqual(cases[0].sources, frozenset({model.ExtractorSource.YT_DLP}))

    def test_load_corpus_reports_line_and_field(self):
        contents = "\n" + json.dumps(
            {
                "id": 123,
                "service": "tiktok",
                "sources": ["yt-dlp"],
                "kinds": ["video"],
                "url": "https://example.test/video",
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "corpus.jsonl"
            path.write_text(contents, encoding="utf-8")

            with self.assertRaisesRegex(model.HarnessError, r"corpus line 2\.id"):
                corpus_data.load_corpus(path)

    def test_load_corpus_rejects_unknown_fields_and_duplicates(self):
        base = {
            "id": "case",
            "service": "tiktok",
            "sources": ["yt-dlp"],
            "kinds": ["video"],
            "url": "https://example.test/video",
        }
        invalid_cases = (
            ({**base, "unknown": True}, r"\.unknown"),
            ({**base, "sources": ["yt-dlp", "yt-dlp"]}, "duplicate"),
        )
        for raw, message in invalid_cases:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "corpus.jsonl"
                path.write_text(json.dumps(raw), encoding="utf-8")

                with self.assertRaisesRegex(model.HarnessError, message):
                    corpus_data.load_corpus(path)

    def test_load_expectations_validates_case_policy(self):
        contents = json.dumps(
            {
                "schema_version": 2,
                "default_rejected": [],
                "profiles": {
                    "no-gallery": {
                        "cases": {
                            "case": {
                                "acceptable": [
                                    {
                                        "terminal_result": "error",
                                        "media_count": 0,
                                        "failure_reason": "authentication_required",
                                    }
                                ],
                                "reason": "requires an authenticated session",
                            }
                        }
                    }
                },
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "expectations.json"
            path.write_text(contents, encoding="utf-8")
            expectations = corpus_data.load_expectations(path)

        expectation = policy.expectation_for(self.corpus_case("case"), expectations)
        self.assertEqual(
            expectation.acceptable[0].failure_reason,
            model.FailureReason.AUTHENTICATION_REQUIRED,
        )

    def test_load_expectations_rejects_non_object_document(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "expectations.json"
            path.write_text("[]", encoding="utf-8")

            with self.assertRaisesRegex(
                model.HarnessError, "expectations must be an object"
            ):
                corpus_data.load_expectations(path)

    def test_load_expectations_reports_nested_schema_path(self):
        contents = json.dumps(
            {
                "schema_version": 2,
                "default_rejected": [],
                "profiles": {
                    "no-gallery": {
                        "cases": {
                            "case": {
                                "acceptable": [
                                    {
                                        "terminal_result": "error",
                                        "media_count": True,
                                    }
                                ]
                            }
                        }
                    }
                },
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "expectations.json"
            path.write_text(contents, encoding="utf-8")

            with self.assertRaisesRegex(
                model.HarnessError,
                r"expectations\.profiles\.no-gallery\.cases\.case"
                r"\.acceptable\[0\]\.media_count",
            ):
                corpus_data.load_expectations(path)

    def test_load_expectations_rejects_unknown_and_duplicate_entries(self):
        base = {
            "schema_version": 2,
            "default_rejected": [],
            "profiles": {"no-gallery": {"cases": {}}},
        }
        invalid_documents = (
            ({**base, "unknown": True}, r"expectations\.unknown"),
            (
                {**base, "default_rejected": ["case", "case"]},
                "duplicate case IDs",
            ),
        )
        for document, message in invalid_documents:
            with (
                self.subTest(document=document),
                tempfile.TemporaryDirectory() as directory,
            ):
                path = Path(directory) / "expectations.json"
                path.write_text(json.dumps(document), encoding="utf-8")

                with self.assertRaisesRegex(model.HarnessError, message):
                    corpus_data.load_expectations(path)

    def test_bundled_expectations_cover_both_profiles(self):
        expectations = corpus_data.load_expectations(config.DEFAULT_EXPECTATIONS)

        self.assertTrue(expectations.cases_for(model.Profile.NO_GALLERY))
        self.assertTrue(expectations.cases_for(model.Profile.GALLERY))
