import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from fake_services_common import read_request_body, write_json


HOST = os.environ["LOLEK_CONCURRENCY_SERVICES_HOST"]
PORT = int(os.environ["LOLEK_CONCURRENCY_SERVICES_PORT"])
TOKEN = os.environ["LOLEK_CONCURRENCY_SERVICES_TOKEN"]
EVENTS_FILE = os.environ["LOLEK_CONCURRENCY_SERVICES_EVENTS_FILE"]
CONTROL_DIR = os.environ["LOLEK_CONCURRENCY_SERVICES_CONTROL_DIR"]
MEDIA_FILE = os.environ["LOLEK_CONCURRENCY_SERVICES_MEDIA_FILE"]


SCENARIOS = {
    "global": [
        {"update_id": 100, "message_id": 10, "name": "global-a", "chat_id": 1001},
        {"update_id": 101, "message_id": 11, "name": "global-b", "chat_id": 1002},
        {"update_id": 102, "message_id": 12, "name": "global-c", "chat_id": 1003},
    ],
    "per-chat": [
        {"update_id": 200, "message_id": 20, "name": "chat-a", "chat_id": 2001},
        {"update_id": 201, "message_id": 21, "name": "chat-b", "chat_id": 2001},
        {"update_id": 202, "message_id": 22, "name": "chat-c", "chat_id": 2002},
    ],
}


PHASE_FILE = os.path.join(CONTROL_DIR, "phase")
MEDIA_BY_PATH = {
    "/media/%s.mp4" % update["name"]: update
    for updates in SCENARIOS.values()
    for update in updates
}


lock = threading.Lock()
started_media = set()
send_video_count = 0

os.makedirs(os.path.dirname(EVENTS_FILE), exist_ok=True)
os.makedirs(CONTROL_DIR, exist_ok=True)


def log_event(message):
    with lock:
        with open(EVENTS_FILE, "a", encoding="utf-8") as log:
            log.write("%s\n" % message)


def current_phase():
    try:
        with open(PHASE_FILE, "r", encoding="utf-8") as phase_file:
            phase = phase_file.read().strip()
    except FileNotFoundError:
        return "global"

    return phase if phase in SCENARIOS else "global"


def media_url(name):
    return "http://%s:%d/media/%s.mp4" % (HOST, PORT, name)


def update_payload(update):
    return {
        "update_id": update["update_id"],
        "message": {
            "message_id": update["message_id"],
            "date": int(time.time()),
            "text": media_url(update["name"]),
            "chat": {"id": update["chat_id"], "type": "private"},
            "from": {
                "id": 5678,
                "is_bot": False,
                "first_name": "Concurrency Test User",
            },
        },
    }


def updates_for_request(body):
    request = json.loads(body.decode("utf-8") or "{}")
    offset = request.get("offset", 0)
    phase = current_phase()

    updates = [
        update_payload(update)
        for update in SCENARIOS[phase]
        if update["update_id"] >= offset
    ]

    log_event("getUpdates %s %d" % (phase, len(updates)))
    return updates


class Handler(BaseHTTPRequestHandler):
    def serve_media(self, update, include_body):
        file_size = os.path.getsize(MEDIA_FILE)

        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(file_size))
        self.end_headers()

        if not include_body:
            return

        name = update["name"]
        should_log_start = False

        with lock:
            if name not in started_media:
                started_media.add(name)
                should_log_start = True

        if should_log_start:
            log_event("media-start %s" % name)

        release_file = os.path.join(CONTROL_DIR, "release-%s" % name)
        while not os.path.exists(release_file):
            time.sleep(0.1)

        with open(MEDIA_FILE, "rb") as media_file:
            self.wfile.write(media_file.read())

        log_event("media-finish %s" % name)

    def do_HEAD(self):
        if self.path in MEDIA_BY_PATH:
            self.serve_media(MEDIA_BY_PATH[self.path], False)
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path in MEDIA_BY_PATH:
            self.serve_media(MEDIA_BY_PATH[self.path], True)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global send_video_count

        body = read_request_body(self)
        method = self.path.rsplit("/", 1)[-1]

        if self.path == "/bot%s/getMe" % TOKEN:
            log_event("%s request" % method)
            write_json(
                self,
                {
                    "ok": True,
                    "result": {
                        "id": 1,
                        "is_bot": True,
                        "first_name": "Lolek Concurrency Test",
                        "username": "lolek_concurrency_test_bot",
                    },
                },
            )
        elif self.path == "/bot%s/deleteWebhook" % TOKEN:
            log_event("%s request" % method)
            write_json(self, {"ok": True, "result": True})
        elif self.path == "/bot%s/setMyCommands" % TOKEN:
            log_event("%s request" % method)
            write_json(self, {"ok": True, "result": True})
        elif self.path == "/bot%s/getUpdates" % TOKEN:
            write_json(self, {"ok": True, "result": updates_for_request(body)})
        elif self.path == "/bot%s/sendVideo" % TOKEN:
            with lock:
                send_video_count += 1
                file_id = "concurrency-video-%d" % send_video_count

            log_event("sendVideo %s" % file_id)
            write_json(
                self,
                {
                    "ok": True,
                    "result": {
                        "message_id": int(time.time()),
                        "date": int(time.time()),
                        "chat": {"id": 1234, "type": "private"},
                        "video": {
                            "file_id": file_id,
                            "file_unique_id": "%s-unique" % file_id,
                            "width": 160,
                            "height": 90,
                            "duration": 1,
                            "file_name": "media.mp4",
                            "mime_type": "video/mp4",
                            "file_size": len(body),
                        },
                    },
                },
            )
        elif self.path == "/bot%s/sendDocument" % TOKEN:
            log_event("%s request" % method)
            write_json(
                self,
                {
                    "ok": True,
                    "result": {
                        "message_id": int(time.time()),
                        "date": int(time.time()),
                        "chat": {"id": 1234, "type": "private"},
                        "document": {
                            "file_id": "concurrency-document",
                            "file_unique_id": "concurrency-document-unique",
                            "file_name": "media.bin",
                            "file_size": len(body),
                        },
                    },
                },
            )
        else:
            log_event("%s request" % method)
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
