import json


def write_json(handler, payload):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


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
