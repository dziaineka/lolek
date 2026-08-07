import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_HOST"]
PORT = int(os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_PORT"])
MEDIA_PATH = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_MEDIA_PATH"]
MEDIA_FILE = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_MEDIA_FILE"]
AUDIO_PATH = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_AUDIO_PATH"]
AUDIO_FILE = os.environ["LOLEK_TIKTOK_AUDIO_SERVICES_AUDIO_FILE"]

MEDIA_BY_PATH = {
    MEDIA_PATH: {"file": MEDIA_FILE, "content_type": "video/mp4"},
    AUDIO_PATH: {"file": AUDIO_FILE, "content_type": "audio/mp4"},
}


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
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
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

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
