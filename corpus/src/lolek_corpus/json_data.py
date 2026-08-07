"""Shared narrowing helpers for dynamic JSON boundaries."""

from __future__ import annotations

from typing import Any, cast

from lolek_corpus.model import HarnessError

type JsonObject = dict[str, Any]


def require_json_object(raw: object, context: str) -> JsonObject:
    """Validate and narrow one dynamic JSON value to an object."""
    if not isinstance(raw, dict):
        raise HarnessError(f"{context} must be an object")
    return cast(JsonObject, raw)


def require_json_object_list(raw: object, context: str) -> tuple[JsonObject, ...]:
    """Validate and narrow a dynamic JSON array of objects."""
    if not isinstance(raw, list) or not all(isinstance(item, dict) for item in raw):
        raise HarnessError(f"{context} must be a list of objects")
    return tuple(cast(list[JsonObject], raw))


def require_non_empty_string(raw: object, context: str) -> str:
    """Validate one required non-empty JSON string."""
    if not isinstance(raw, str) or not raw:
        raise HarnessError(f"{context} must be a non-empty string")
    return raw
