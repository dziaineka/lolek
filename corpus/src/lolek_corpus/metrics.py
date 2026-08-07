"""Typed access to the Lolek metrics used by live corpus tests."""

from __future__ import annotations

import dataclasses
import re
import urllib.request
from collections.abc import Mapping

from lolek_corpus.model import HarnessError, TerminalResult

MESSAGE_RESULT_PATTERN = re.compile(
    r'^lolek_messages_total\{result="([^"]+)"\} ([0-9]+)$', re.MULTILINE
)
CACHE_LOOKUP_PATTERN = re.compile(
    r'^lolek_cache_lookup_total\{state="([^"]+)"\} ([0-9]+)$', re.MULTILINE
)


class CacheLookupState(str):
    """An extensible Lolek cache-state metric label."""


CACHE_NEW_FILE = CacheLookupState("new_file")
CACHE_READY_TO_TELEGRAM = CacheLookupState("ready_to_telegram")


@dataclasses.dataclass(frozen=True)
class MetricSnapshot:
    """The Lolek metrics needed to observe one corpus request."""

    message_results: Mapping[TerminalResult, int]
    cache_lookups: Mapping[CacheLookupState, int]
    processing_active: int
    processing_waiting: int

    @property
    def message_total(self) -> int:
        """Return the number of terminal message results observed so far."""
        return sum(self.message_results.values())

    @property
    def idle(self) -> bool:
        """Return whether no processing task is active or queued."""
        return self.processing_active == 0 and self.processing_waiting == 0

    def terminal_result_since(self, before: MetricSnapshot) -> TerminalResult:
        """Return the single terminal result added after an earlier snapshot."""
        labels = set(before.message_results) | set(self.message_results)
        deltas = {
            label: self.message_results.get(label, 0)
            - before.message_results.get(label, 0)
            for label in labels
            if self.message_results.get(label, 0)
            != before.message_results.get(label, 0)
        }
        if (
            deltas
            and sum(deltas.values()) == 1
            and all(delta >= 0 for delta in deltas.values())
        ):
            return next(label for label, delta in deltas.items() if delta == 1)
        raise HarnessError(f"expected one terminal metric increment, got {deltas!r}")

    def cache_increment_since(
        self, before: MetricSnapshot, state: CacheLookupState
    ) -> int:
        """Return the change in one cache-state counter."""
        return self.cache_lookups.get(state, 0) - before.cache_lookups.get(state, 0)


@dataclasses.dataclass(frozen=True)
class LolekMetrics:
    """Fetch and decode the stable metrics exposed by one Lolek process."""

    url: str

    def snapshot(self) -> MetricSnapshot:
        """Fetch one typed metric snapshot."""
        request = urllib.request.Request(self.url)
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                text = response.read().decode("utf-8")
        except OSError as error:
            raise HarnessError(f"could not fetch Lolek metrics: {error}") from error
        return parse_snapshot(text)


def parse_snapshot(text: str) -> MetricSnapshot:
    """Decode the Lolek metrics relevant to the corpus harness."""
    return MetricSnapshot(
        message_results={
            TerminalResult(label): int(value)
            for label, value in MESSAGE_RESULT_PATTERN.findall(text)
        },
        cache_lookups={
            CacheLookupState(label): int(value)
            for label, value in CACHE_LOOKUP_PATTERN.findall(text)
        },
        processing_active=_integer_gauge(text, "lolek_processing_active"),
        processing_waiting=_integer_gauge(text, "lolek_processing_waiting"),
    )


def _integer_gauge(text: str, name: str) -> int:
    """Read an unlabeled integer gauge from Prometheus text."""
    match = re.search(rf"^{re.escape(name)} (-?[0-9]+)$", text, re.MULTILINE)
    if not match:
        raise HarnessError(f"metric {name!r} is missing")
    return int(match.group(1))
