"""Console entry point for the live corpus runner."""

from __future__ import annotations

import sys

from lolek_corpus import runner
from lolek_corpus.model import HarnessError


def cli() -> int:
    """Run the command and preserve the inconclusive harness exit code."""
    try:
        return runner.main()
    except HarnessError as error:
        print(f"live corpus harness error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(cli())
