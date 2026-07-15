import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from fake_services_common import read_request_body, write_json


HOST = os.environ["LOLEK_DEADLINE_SERVICES_HOST"]
PORT = int(os.environ["LOLEK_DEADLINE_SERVICES_PORT"])
TOKEN = os.environ["LOLEK_DEADLINE_SERVICES_TOKEN"]
EVENTS_FILE = os.environ["LOLEK_DEADLINE_SERVICES_EVENTS_FILE"]

MEDIA_PATH = "/media/deadline.mp4"
UPDATE_ID = 100

lock = threading.Lock()

os.makedirs(os.path.dirname(EVENTS_FILE), exist_ok=True)


def log_event(message):
    with lock:
        with open(EVENTS_FILE, "a", encoding="utf-8") as log:
            log.write("%s\n" % message)


def update_payload():
    return {
        "update_id": UPDATE_ID,
        "message": {
            "message_id": 10,
            "date": int(time.time()),
            "text": "http://%s:%d%s" % (HOST, PORT, MEDIA_PATH),
            "chat": {"id": 1001, "type": "private"},
            "from": {
                "id": 5678,
                "is_bot": False,
                "first_name": "Deadline Test User",
            },
        },
    }


class Handler(BaseHTTPRequestHandler):
    def serve_media(self, include_body):
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", "1024")
        self.end_headers()

        if not include_body:
            return

        log_event("media-start")

        # A real downloader remains blocked here until Lolek's request-wide
        # deadline cancels it and closes the connection.
        while True:
            time.sleep(1)

    def do_HEAD(self):
        if self.path == MEDIA_PATH:
            self.serve_media(False)
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == MEDIA_PATH:
            self.serve_media(True)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        body = read_request_body(self)
        method = self.path.rsplit("/", 1)[-1]

        if self.path == "/bot%s/getMe" % TOKEN:
            write_json(
                self,
                {
                    "ok": True,
                    "result": {
                        "id": 1,
                        "is_bot": True,
                        "first_name": "Lolek Deadline Test",
                        "username": "lolek_deadline_test_bot",
                    },
                },
            )
        elif self.path in (
            "/bot%s/deleteWebhook" % TOKEN,
            "/bot%s/setMyCommands" % TOKEN,
        ):
            write_json(self, {"ok": True, "result": True})
        elif self.path == "/bot%s/getUpdates" % TOKEN:
            request = json.loads(body.decode("utf-8") or "{}")
            updates = (
                [update_payload()] if request.get("offset", 0) <= UPDATE_ID else []
            )

            if updates:
                log_event("getUpdates update")

            write_json(self, {"ok": True, "result": updates})
        elif method.startswith("send") or method.startswith("editMessage"):
            log_event("telegram-upload %s" % method)
            write_json(self, {"ok": True, "result": True})
        else:
            log_event("unexpected-telegram-request %s" % method)
            write_json(
                self,
                {
                    "ok": False,
                    "error_code": 404,
                    "description": "Unknown fake services endpoint",
                },
            )

    def log_message(self, format, *args):
        return


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
