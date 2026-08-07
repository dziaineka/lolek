import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ["LOLEK_CONCURRENCY_ORIGIN_HOST"]
PORT = int(os.environ["LOLEK_CONCURRENCY_ORIGIN_PORT"])
EVENTS_FILE = os.environ["LOLEK_CONCURRENCY_ORIGIN_EVENTS_FILE"]
CONTROL_DIR = os.environ["LOLEK_CONCURRENCY_ORIGIN_CONTROL_DIR"]
MEDIA_FILE = os.environ["LOLEK_CONCURRENCY_ORIGIN_MEDIA_FILE"]


MEDIA_NAMES = [
    "global-a",
    "global-b",
    "global-c",
    "chat-a",
    "chat-b",
    "chat-c",
    "rate-a",
    "rate-b",
    "rate-c",
    "rate-d",
    "rate-e",
]
MEDIA_BY_PATH = {f"/media/{name}.mp4": name for name in MEDIA_NAMES}


lock = threading.Lock()
started_media = set()

os.makedirs(os.path.dirname(EVENTS_FILE), exist_ok=True)
os.makedirs(CONTROL_DIR, exist_ok=True)


def log_event(message):
    with lock, open(EVENTS_FILE, "a", encoding="utf-8") as log:
        log.write(f"{message}\n")


class Handler(BaseHTTPRequestHandler):
    def serve_media(self, name, include_body):
        file_size = os.path.getsize(MEDIA_FILE)

        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(file_size))
        self.end_headers()

        if not include_body:
            return

        should_log_start = False
        with lock:
            if name not in started_media:
                started_media.add(name)
                should_log_start = True

        if should_log_start:
            log_event(f"media-start {name}")

        release_file = os.path.join(CONTROL_DIR, f"release-{name}")
        while not os.path.exists(release_file):
            time.sleep(0.1)

        with open(MEDIA_FILE, "rb") as media_file:
            self.wfile.write(media_file.read())

        log_event(f"media-finish {name}")

    def do_HEAD(self):
        name = MEDIA_BY_PATH.get(self.path)
        if name is None:
            self.send_response(404)
            self.end_headers()
        else:
            self.serve_media(name, False)

    def do_GET(self):
        name = MEDIA_BY_PATH.get(self.path)
        if name is None:
            self.send_response(404)
            self.end_headers()
        else:
            self.serve_media(name, True)

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
