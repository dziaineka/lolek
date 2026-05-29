import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = os.environ["LOLEK_FAKE_SERVICES_HOST"]
LOG_DIR = os.environ["LOLEK_FAKE_SERVICES_LOG_DIR"]
EVENTS_FILE = os.environ["LOLEK_FAKE_SERVICES_EVENTS_FILE"]
UPLOAD_FILE = os.environ["LOLEK_FAKE_SERVICES_UPLOAD_FILE"]
MEDIA_FILE = os.environ["LOLEK_FAKE_SERVICES_MEDIA_FILE"]
MEDIA_PATH = os.environ["LOLEK_FAKE_SERVICES_MEDIA_PATH"]
PORT = int(os.environ["LOLEK_FAKE_SERVICES_PORT"])
TOKEN = os.environ["LOLEK_FAKE_SERVICES_TOKEN"]
VIDEO_FILE_ID = os.environ["LOLEK_FAKE_SERVICES_VIDEO_FILE_ID"]
VIDEO_FILE_UNIQUE_ID = os.environ["LOLEK_FAKE_SERVICES_VIDEO_FILE_UNIQUE_ID"]
VIDEO_WIDTH = int(os.environ["LOLEK_FAKE_SERVICES_VIDEO_WIDTH"])
VIDEO_HEIGHT = int(os.environ["LOLEK_FAKE_SERVICES_VIDEO_HEIGHT"])
VIDEO_DURATION = int(os.environ["LOLEK_FAKE_SERVICES_VIDEO_DURATION"])
DOCUMENT_FILE_ID = os.environ["LOLEK_FAKE_SERVICES_DOCUMENT_FILE_ID"]
DOCUMENT_FILE_UNIQUE_ID = os.environ["LOLEK_FAKE_SERVICES_DOCUMENT_FILE_UNIQUE_ID"]

MEDIA_URL = "http://%s:%d%s" % (HOST, PORT, MEDIA_PATH)

os.makedirs(LOG_DIR, exist_ok=True)
uploaded = False


def write_json(handler, payload):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def log_event(method, body):
    with open(EVENTS_FILE, "a", encoding="utf-8") as log:
        log.write("%s %d\n" % (method, len(body)))


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
    def serve_media(self, include_body):
        file_size = os.path.getsize(MEDIA_FILE)
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
            with open(MEDIA_FILE, "rb") as media:
                media.seek(start)
                self.wfile.write(media.read(length))

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
        global uploaded

        body = read_request_body(self)
        method = self.path.rsplit("/", 1)[-1]
        log_event(method, body)

        if self.path == "/bot%s/getMe" % TOKEN:
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
            write_json(self, {"ok": True, "result": True})
        elif self.path == "/bot%s/setMyCommands" % TOKEN:
            write_json(self, {"ok": True, "result": True})
        elif self.path == "/bot%s/getUpdates" % TOKEN:
            if uploaded:
                updates = []
            else:
                updates = [
                    {
                        "update_id": 100,
                        "message": {
                            "message_id": 10,
                            "date": int(time.time()),
                            "text": MEDIA_URL,
                            "chat": {"id": 1234, "type": "private"},
                            "from": {
                                "id": 5678,
                                "is_bot": False,
                                "first_name": "Test User",
                            },
                        },
                    }
                ]

            write_json(self, {"ok": True, "result": updates})
        elif self.path == "/bot%s/sendVideo" % TOKEN:
            uploaded = True

            if b"filename=" in body or not os.path.exists(UPLOAD_FILE):
                with open(UPLOAD_FILE, "wb") as upload:
                    upload.write(body)

            write_json(
                self,
                {
                    "ok": True,
                    "result": {
                        "message_id": 11,
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
                },
            )
        elif self.path == "/bot%s/sendDocument" % TOKEN:
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
