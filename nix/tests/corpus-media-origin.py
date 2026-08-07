import json
import mimetypes
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

HOST = os.environ["LOLEK_TEST_CORPUS_ORIGIN_HOST"]
PORT = int(os.environ["LOLEK_TEST_CORPUS_ORIGIN_PORT"])
FIXTURES = json.loads(
    Path(os.environ["LOLEK_TEST_CORPUS_FIXTURE_MANIFEST"]).read_text(encoding="utf-8")
)
EVENTS = []
EVENTS_LOCK = threading.Lock()


def record_event(event):
    with EVENTS_LOCK:
        EVENTS.append(event)


def events_snapshot():
    with EVENTS_LOCK:
        return list(EVENTS)


class Handler(BaseHTTPRequestHandler):
    def write_json(self, payload, status=200):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/debug/events":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        event = json.loads(self.rfile.read(length))
        record_event(event)
        self.write_json({"ok": True})

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self.write_json({"status": "ok"})
            return

        if parsed.path == "/debug/events":
            self.write_json({"events": events_snapshot()})
            return

        parts = [unquote(part) for part in parsed.path.split("/") if part]
        if len(parts) != 3 or parts[0] != "media":
            self.send_response(404)
            self.end_headers()
            return

        _media, case_id, fixture = parts
        fixture_path = FIXTURES.get(fixture)
        if fixture_path is None:
            self.send_response(404)
            self.end_headers()
            return

        body = Path(fixture_path).read_bytes()
        record_event({"type": "media", "case_id": case_id, "fixture": fixture})
        self.send_response(200)
        self.send_header(
            "Content-Type",
            mimetypes.guess_type(fixture)[0] or "application/octet-stream",
        )
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
