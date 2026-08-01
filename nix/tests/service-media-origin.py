import os
from enum import Enum
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = os.environ["LOLEK_MEDIA_ORIGIN_HOST"]
PORT = int(os.environ["LOLEK_MEDIA_ORIGIN_PORT"])


class MediaKind(Enum):
    PASSTHROUGH = "passthrough"
    LEGACY = "legacy"
    COMPRESSED = "compressed"


MEDIA = {
    MediaKind.PASSTHROUGH: {
        "path": os.environ["LOLEK_MEDIA_ORIGIN_PASSTHROUGH_PATH"],
        "file": os.environ["LOLEK_MEDIA_ORIGIN_PASSTHROUGH_FILE"],
    },
    MediaKind.LEGACY: {
        "path": os.environ["LOLEK_MEDIA_ORIGIN_LEGACY_PATH"],
        "file": os.environ["LOLEK_MEDIA_ORIGIN_LEGACY_FILE"],
        "downloadable": False,
    },
    MediaKind.COMPRESSED: {
        "path": os.environ["LOLEK_MEDIA_ORIGIN_COMPRESSED_PATH"],
        "file": os.environ["LOLEK_MEDIA_ORIGIN_COMPRESSED_FILE"],
    },
}

for media in MEDIA.values():
    media.setdefault("downloadable", True)

MEDIA_BY_PATH = {media["path"]: media for media in MEDIA.values()}


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

    def serve_path(self, include_body):
        media = MEDIA_BY_PATH.get(self.path)
        if media is None:
            self.send_response(404)
            self.end_headers()
        elif media["downloadable"]:
            self.serve_media(media, include_body)
        else:
            self.send_response(503)
            self.end_headers()

    def do_HEAD(self):
        self.serve_path(False)

    def do_GET(self):
        self.serve_path(True)

    def log_message(self, format, *args):
        return


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
