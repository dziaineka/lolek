import json
import os
import time
from enum import Enum
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

from fake_services_common import read_request_body, write_json


HOST = os.environ["LOLEK_FAKE_SERVICES_HOST"]
LOG_DIR = os.environ["LOLEK_FAKE_SERVICES_LOG_DIR"]
EVENTS_FILE = os.environ["LOLEK_FAKE_SERVICES_EVENTS_FILE"]
UPLOAD_DIR = os.environ["LOLEK_FAKE_SERVICES_UPLOAD_DIR"]
PORT = int(os.environ["LOLEK_FAKE_SERVICES_PORT"])
TOKEN = os.environ["LOLEK_FAKE_SERVICES_TOKEN"]
DOCUMENT_FILE_ID = os.environ["LOLEK_FAKE_SERVICES_DOCUMENT_FILE_ID"]
DOCUMENT_FILE_UNIQUE_ID = os.environ["LOLEK_FAKE_SERVICES_DOCUMENT_FILE_UNIQUE_ID"]


class MediaKind(Enum):
    PASSTHROUGH = "passthrough"
    COMPRESSED = "compressed"


PASSTHROUGH_UPLOAD_UPDATE_ID = 100
PASSTHROUGH_REUSE_UPDATE_ID = 101
COMPRESSED_UPLOAD_UPDATE_ID = 102


MEDIA = {
    MediaKind.PASSTHROUGH: {
        "path": os.environ["LOLEK_FAKE_SERVICES_PASSTHROUGH_MEDIA_PATH"],
        "file": os.environ["LOLEK_FAKE_SERVICES_PASSTHROUGH_MEDIA_FILE"],
        "file_id": os.environ["LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_FILE_ID"],
        "file_unique_id": os.environ[
            "LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_FILE_UNIQUE_ID"
        ],
        "width": int(os.environ["LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_WIDTH"]),
        "height": int(os.environ["LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_HEIGHT"]),
        "duration": int(os.environ["LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_DURATION"]),
    },
    MediaKind.COMPRESSED: {
        "path": os.environ["LOLEK_FAKE_SERVICES_COMPRESSED_MEDIA_PATH"],
        "file": os.environ["LOLEK_FAKE_SERVICES_COMPRESSED_MEDIA_FILE"],
        "file_id": os.environ["LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_FILE_ID"],
        "file_unique_id": os.environ[
            "LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_FILE_UNIQUE_ID"
        ],
        "width": int(os.environ["LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_WIDTH"]),
        "height": int(os.environ["LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_HEIGHT"]),
        "duration": int(os.environ["LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_DURATION"]),
    },
}

for kind, media in MEDIA.items():
    media["kind"] = kind
    media["url"] = "http://%s:%d%s" % (HOST, PORT, media["path"])
    media["upload_file"] = os.path.join(UPLOAD_DIR, "%s.bin" % kind.value)

MEDIA_BY_PATH = {media["path"]: media for media in MEDIA.values()}
MEDIA_BY_FILE_ID = {media["file_id"]: media for media in MEDIA.values()}

os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(UPLOAD_DIR, exist_ok=True)
uploaded = set()
sent_by_file_id = set()


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
        self.send_header("Content-Type", "video/mp4")
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

    def update_for_media(self, kind: MediaKind, update_id, message_id):
        media = MEDIA[kind]

        return {
            "update_id": update_id,
            "message": {
                "message_id": message_id,
                "date": int(time.time()),
                "text": media["url"],
                "chat": {"id": 1234, "type": "private"},
                "from": {
                    "id": 5678,
                    "is_bot": False,
                    "first_name": "Test User",
                },
            },
        }

    def updates(self, body):
        request = json.loads(body.decode("utf-8") or "{}")
        offset = request.get("offset", 0)

        if (
            offset <= PASSTHROUGH_UPLOAD_UPDATE_ID
            and MediaKind.PASSTHROUGH not in uploaded
        ):
            return [
                self.update_for_media(
                    MediaKind.PASSTHROUGH, PASSTHROUGH_UPLOAD_UPDATE_ID, 10
                )
            ]

        if (
            offset <= PASSTHROUGH_REUSE_UPDATE_ID
            and MediaKind.PASSTHROUGH in uploaded
            and MediaKind.PASSTHROUGH not in sent_by_file_id
        ):
            return [
                self.update_for_media(
                    MediaKind.PASSTHROUGH, PASSTHROUGH_REUSE_UPDATE_ID, 11
                )
            ]

        if (
            offset <= COMPRESSED_UPLOAD_UPDATE_ID
            and MediaKind.PASSTHROUGH in sent_by_file_id
            and MediaKind.COMPRESSED not in uploaded
        ):
            return [
                self.update_for_media(
                    MediaKind.COMPRESSED, COMPRESSED_UPLOAD_UPDATE_ID, 12
                )
            ]

        return []

    def video_response(self, media, body):
        return {
            "ok": True,
            "result": {
                "message_id": int(time.time()),
                "date": int(time.time()),
                "chat": {"id": 1234, "type": "private"},
                "video": {
                    "file_id": media["file_id"],
                    "file_unique_id": media["file_unique_id"],
                    "width": media["width"],
                    "height": media["height"],
                    "duration": media["duration"],
                    "file_name": "media.mp4",
                    "mime_type": "video/mp4",
                    "file_size": len(body),
                },
            },
        }

    def upload_media(self, body):
        if b"filename=" not in body:
            body_text = body.decode("utf-8")
            try:
                request = json.loads(body_text or "{}")
            except json.JSONDecodeError:
                request = {
                    key: values[0] for key, values in parse_qs(body_text).items()
                }

            file_id = request.get("video")
            media = MEDIA_BY_FILE_ID[file_id]
            sent_by_file_id.add(media["kind"])
            return (
                media,
                "%s-file-id-send" % media["kind"].value,
            )

        if MediaKind.PASSTHROUGH not in uploaded:
            kind = MediaKind.PASSTHROUGH
        else:
            kind = MediaKind.COMPRESSED

        media = MEDIA[kind]

        with open(media["upload_file"], "wb") as upload:
            upload.write(body)

        uploaded.add(kind)
        return media, "%s-upload" % kind.value

    def do_POST(self):
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
            media, detail = self.upload_media(body)
            log_event(method, detail, body)
            write_json(self, self.video_response(media, body))
        elif self.path == "/bot%s/sendDocument" % TOKEN:
            log_event(method, detail, body)
            write_json(
                self,
                {
                    "ok": True,
                    "result": {
                        "message_id": 12,
                        "date": int(time.time()),
                        "chat": {"id": 1234, "type": "private"},
                        "document": {
                            "file_id": DOCUMENT_FILE_ID,
                            "file_unique_id": DOCUMENT_FILE_UNIQUE_ID,
                            "file_name": "media.bin",
                            "file_size": len(body),
                        },
                    },
                },
            )
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
