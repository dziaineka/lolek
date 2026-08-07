"""Tests for live run workspace ownership."""

import tempfile
from pathlib import Path

from support import CorpusTestCase

from lolek_corpus import workspace


class WorkspaceTest(CorpusTestCase):
    """Cover cleanup of runner-owned temporary files."""

    def test_run_workspace_cleans_owned_temporary_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_workspace = workspace.RunWorkspace(
                keep=False,
                temporary_root=root,
                lock_path=root / "live-corpus.lock",
            )
            with run_workspace:
                work_dir = run_workspace.path
                (work_dir / "capture").write_text("media", encoding="utf-8")

            self.assertFalse(work_dir.exists())
