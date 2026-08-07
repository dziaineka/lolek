"""Shared typed fixtures for live corpus unit tests."""

import unittest

from lolek_corpus import config, model


class CorpusTestCase(unittest.TestCase):
    """Provide compact constructors for corpus runner domain objects."""

    @staticmethod
    def runner_config(*extra_args):
        return config.parse_args(
            [
                "--corpus",
                "corpus.jsonl",
                "--lolek",
                "lolek",
                "--telegym",
                "telegym-mock",
                "--ffprobe",
                "ffprobe",
                *extra_args,
            ]
        )

    def corpus_case(
        self,
        case_id,
        service=model.Service.TIKTOK,
        sources=(model.ExtractorSource.YT_DLP,),
    ):
        return model.CorpusCase(
            id=case_id,
            service=service,
            sources=frozenset(sources),
            kinds=(model.CorpusMediaKind.VIDEO,),
            url=f"https://example.test/{case_id}",
        )

    def observation(
        self,
        terminal_result,
        media_count,
        media_kinds=(),
        failure_reason=None,
        rate_limited=False,
    ):
        return model.Observation(
            terminal_result=model.TerminalResult(terminal_result),
            media_count=media_count,
            media_kinds=tuple(media_kinds),
            rate_limited=rate_limited,
            failure_reason=failure_reason,
        )
