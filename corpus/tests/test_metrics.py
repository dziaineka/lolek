"""Tests for typed Lolek metrics snapshots."""

import dataclasses

from support import CorpusTestCase

from lolek_corpus import metrics, model


class MetricsTest(CorpusTestCase):
    """Cover relevant Prometheus parsing and snapshot deltas."""

    def test_prometheus_terminal_delta(self):
        metrics_text = """
lolek_messages_total{result="error"} 2
lolek_messages_total{result="ok"} 4
lolek_cache_lookup_total{state="new_file"} 3
lolek_processing_active 0
lolek_processing_waiting 0
"""
        snapshot = metrics.parse_snapshot(metrics_text)
        before = dataclasses.replace(
            snapshot,
            message_results={model.TERMINAL_ERROR: 1, model.TERMINAL_OK: 4},
        )

        self.assertEqual(
            snapshot.message_results,
            {model.TERMINAL_ERROR: 2, model.TERMINAL_OK: 4},
        )
        self.assertEqual(snapshot.cache_lookups, {metrics.CACHE_NEW_FILE: 3})
        self.assertTrue(snapshot.idle)
        self.assertEqual(
            snapshot.terminal_result_since(before),
            model.TERMINAL_ERROR,
        )
