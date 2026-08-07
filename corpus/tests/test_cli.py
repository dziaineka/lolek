"""Tests for the live corpus console entry point."""

import contextlib
import io
from unittest import mock

from support import CorpusTestCase

from lolek_corpus import cli, model, runner


class CliTest(CorpusTestCase):
    """Cover process-level harness error handling."""

    def test_cli_treats_harness_failure_as_inconclusive(self):
        with (
            mock.patch.object(
                runner, "main", side_effect=model.HarnessError("startup")
            ),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(cli.cli(), 2)
