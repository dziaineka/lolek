import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ["LOLEK_DEADLINE_ORIGIN_HOST"]
PORT = int(os.environ["LOLEK_DEADLINE_ORIGIN_PORT"])
EVENTS_FILE = os.environ["LOLEK_DEADLINE_ORIGIN_EVENTS_FILE"]
MEDIA_PATH = "/media/deadline.mp4"


lock = threading.Lock()
os.makedirs(os.path.dirname(EVENTS_FILE), exist_ok=True)


def log_event(message):
    with lock, open(EVENTS_FILE, "a", encoding="utf-8") as log:
        log.write(f"{message}\n")


class Handler(BaseHTTPRequestHandler):
    def serve_media(self, include_body):
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", "1024")
        self.end_headers()

        if not include_body:
            return

        log_event("media-start")

        # Remain blocked until Lolek's request-wide deadline closes the
        # downloader connection.
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

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
