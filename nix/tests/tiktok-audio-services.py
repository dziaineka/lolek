import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from fake_services_common import read_request_body, write_json


HOST = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_HOST"]
PORT = int(os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_PORT"])
TOKEN = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_TOKEN"]
EVENTS_FILE = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_EVENTS_FILE"]
UPLOAD_FILE = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_UPLOAD_FILE"]
MEDIA_PATH = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_MEDIA_PATH"]
MEDIA_FILE = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_MEDIA_FILE"]
AUDIO_PATH = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_AUDIO_PATH"]
AUDIO_FILE = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_AUDIO_FILE"]
VIDEO_FILE_ID = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_FILE_ID"]
VIDEO_FILE_UNIQUE_ID = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_FILE_UNIQUE_ID"]
VIDEO_WIDTH = int(os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_WIDTH"])
VIDEO_HEIGHT = int(os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_HEIGHT"])
VIDEO_DURATION = int(os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_DURATION"])

UPDATE_ID = 100
LOG_DIR = os.path.dirname(EVENTS_FILE)
MEDIA_BY_PATH = {
    MEDIA_PATH: {"file": MEDIA_FILE, "content_type": "video/mp4"},
    AUDIO_PATH: {"file": AUDIO_FILE, "content_type": "audio/mp4"},
}

os.makedirs(LOG_DIR, exist_ok=True)
uploaded = False


def log_event(method, detail, body):
    with open(EVENTS_FILE, "a", encoding="utf-8") as log:
        log.write("%s %s %d\n" % (method, detail, len(body)))


class Handler(BaseHTTPRequestHandler):
    def serve_media(self, media, include_body):
        file_size = os.path.getsize(media["file"])
        range_header = self.headers.get("Range")
        start = 0
        end = file_size - 1
        status = 200

        if range_header and range_header.startswith("bytes="):
            requested = range_header.removeprefix("bytes=").split("-", 1)
            if requested[0]:
                start = int(requested[0])
            if requested[1]:
                end = min(int(requested[1]), file_size - 1)
            status = 206

        length = max(end - start + 1, 0)

        self.send_response(status)
        self.send_header("Content-Type", media["content_type"])
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header(
                "Content-Range", "bytes %d-%d/%d" % (start, end, file_size)
            )
        self.end_headers()

        if include_body:
            with open(media["file"], "rb") as media_file:
                media_file.seek(start)
                self.wfile.write(media_file.read(length))

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

    def updates(self, body):
        request = json.loads(body.decode("utf-8") or "{}")
        offset = request.get("offset", 0)

        if offset <= UPDATE_ID and not uploaded:
            return [
                {
                    "update_id": UPDATE_ID,
                    "message": {
                        "message_id": 10,
                        "date": int(time.time()),
                        "text": "http://%s:%d%s" % (HOST, PORT, MEDIA_PATH),
                        "chat": {"id": 1234, "type": "private"},
                        "from": {
                            "id": 5678,
                            "is_bot": False,
                            "first_name": "Test User",
                        },
                    },
                }
            ]

        return []

    def video_response(self, body):
        return {
            "ok": True,
            "result": {
                "message_id": int(time.time()),
                "date": int(time.time()),
                "chat": {"id": 1234, "type": "private"},
                "video": {
                    "file_id": VIDEO_FILE_ID,
                    "file_unique_id": VIDEO_FILE_UNIQUE_ID,
                    "width": VIDEO_WIDTH,
                    "height": VIDEO_HEIGHT,
                    "duration": VIDEO_DURATION,
                    "file_name": "media.mp4",
                    "mime_type": "video/mp4",
                    "file_size": len(body),
                },
            },
        }

    def do_POST(self):
        global uploaded

        body = read_request_body(self)
        method = self.path.rsplit("/", 1)[-1]
        detail = "request"

        if self.path == "/bot%s/getMe" % TOKEN:
            log_event(method, detail, body)
            write_json(
                self,
                {
                    "ok": True,
                    "result": {
                        "id": 1,
                        "is_bot": True,
                        "first_name": "Lolek Test",
                        "username": "lolek_test_bot",
                    },
                },
            )
        elif self.path == "/bot%s/deleteWebhook" % TOKEN:
            log_event(method, detail, body)
            write_json(self, {"ok": True, "result": True})
        elif self.path == "/bot%s/setMyCommands" % TOKEN:
            log_event(method, detail, body)
            write_json(self, {"ok": True, "result": True})
        elif self.path == "/bot%s/getUpdates" % TOKEN:
            log_event(method, detail, body)
            write_json(self, {"ok": True, "result": self.updates(body)})
        elif self.path == "/bot%s/sendVideo" % TOKEN:
            with open(UPLOAD_FILE, "wb") as upload:
                upload.write(body)

            uploaded = True
            log_event(method, "upload", body)
            write_json(self, self.video_response(body))
        else:
            log_event(method, detail, body)
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
