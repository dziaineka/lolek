"""Load and validate corpus cases and expectation policy files."""

from __future__ import annotations

import json
from pathlib import Path

from pydantic import ValidationError

from lolek_corpus.json_data import require_json_object
from lolek_corpus.model import CorpusCase, CorpusPolicy, HarnessError
from lolek_corpus.schemas import (
    CorpusCaseInput,
    ExpectationsInput,
    harness_validation_error,
)


def load_corpus(path: Path) -> list[CorpusCase]:
    """Load and validate a JSON Lines corpus."""
    cases = []
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            if line.strip():
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError as error:
                    raise HarnessError(
                        f"corpus line {line_number} is invalid JSON: {error.msg}"
                    ) from error
                cases.append(parse_corpus_case(raw, line_number))
    ids = [case.id for case in cases]
    if len(ids) != len(set(ids)):
        raise HarnessError("corpus contains duplicate case IDs")
    urls = [case.url for case in cases]
    if len(urls) != len(set(urls)):
        raise HarnessError("corpus contains duplicate URLs")
    return cases


def parse_corpus_case(raw: object, line_number: int) -> CorpusCase:
    """Parse one corpus JSON object with a line-aware error context."""
    context = f"corpus line {line_number}"
    try:
        parsed = CorpusCaseInput.model_validate(raw)
    except ValidationError as error:
        raise harness_validation_error(context, error) from error
    return parsed.to_domain()


def load_expectations(path: Path) -> CorpusPolicy:
    """Load and parse the shared corpus expectation policy."""
    try:
        with path.open(encoding="utf-8") as source:
            data = json.load(source)
    except json.JSONDecodeError as error:
        raise HarnessError(f"expectations are invalid JSON: {error.msg}") from error
    data = require_json_object(data, "expectations")
    try:
        parsed = ExpectationsInput.model_validate(data)
    except ValidationError as error:
        raise harness_validation_error("expectations", error) from error
    return parsed.to_domain()
