import json
import os
import time
from enum import Enum
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


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
        "update_id": 100,
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
        "update_id": 101,
    },
}

for kind, media in MEDIA.items():
    media["url"] = "http://%s:%d%s" % (HOST, PORT, media["path"])
    media["upload_file"] = os.path.join(UPLOAD_DIR, "%s.bin" % kind.value)

MEDIA_BY_PATH = {media["path"]: media for media in MEDIA.values()}
MEDIA_BY_FILE_ID = {media["file_id"]: media for media in MEDIA.values()}

os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(UPLOAD_DIR, exist_ok=True)
uploaded = set()


def write_json(handler, payload):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def log_event(method, detail, body):
    with open(EVENTS_FILE, "a", encoding="utf-8") as log:
        log.write("%s %s %d\n" % (method, detail, len(body)))


def read_chunked_body(request):
    body = bytearray()

    while True:
        chunk_header = request.rfile.readline().split(b";", 1)[0].strip()
        chunk_size = int(chunk_header, 16)

        if chunk_size == 0:
            while request.rfile.readline() not in (b"\r\n", b"\n", b""):
                pass
            return bytes(body)

        body.extend(request.rfile.read(chunk_size))
        request.rfile.read(2)


def read_request_body(request):
    if request.headers.get("Transfer-Encoding", "").lower() == "chunked":
        return read_chunked_body(request)

    length = int(request.headers.get("Content-Length", "0"))
    return request.rfile.read(length)


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

    def update_for_media(self, kind: MediaKind, message_id):
        media = MEDIA[kind]

        return {
            "update_id": media["update_id"],
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
            offset <= MEDIA[MediaKind.PASSTHROUGH]["update_id"]
            and MediaKind.PASSTHROUGH not in uploaded
        ):
            return [self.update_for_media(MediaKind.PASSTHROUGH, 10)]

        if (
            offset <= MEDIA[MediaKind.COMPRESSED]["update_id"]
            and MediaKind.PASSTHROUGH in uploaded
            and MediaKind.COMPRESSED not in uploaded
        ):
            return [self.update_for_media(MediaKind.COMPRESSED, 11)]

        return []

    def video_response(self, media, body):
        return {
            "ok": True,
            "result": {
                "message_id": media["update_id"],
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
            request = json.loads(body.decode("utf-8") or "{}")
            file_id = request.get("video")
            return (
                MEDIA_BY_FILE_ID.get(file_id, MEDIA[MediaKind.PASSTHROUGH]),
                "file-id-send",
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
