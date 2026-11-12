def test_video_budget(machine, subtest, media_dir):
    """Check encoding targets separately from upload limits through the live bot."""
    import json
    import shlex

    api = "http://127.0.0.1:5678"
    target = 41_000
    ceiling = 200_000

    machine.wait_until_succeeds(
        f"curl -fsS {api}/debug/bots | "
        "jq -e '.bots | any(.token_full == \"dummy-token\")' >/dev/null"
    )

    def size(path):
        return int(machine.succeed(f"stat -c %s {shlex.quote(path)}"))

    def upload(name, chat_id):
        payload = json.dumps(
            {
                "token": "dummy-token",
                "chat_id": chat_id,
                "username": "test_user",
                "first_name": "Test User",
                "text": f"http://127.0.0.1:8081/{name}.mp4",
            }
        )
        machine.succeed(
            "curl -fsS -H 'Content-Type: application/json' "
            f"--data {shlex.quote(payload)} {api}/debug/inject/update"
        )
        messages = f"{api}/debug/messages/dummy-token?chat_id={chat_id}"
        machine.wait_until_succeeds(
            f"curl -fsS {shlex.quote(messages)} | "
            "jq -e 'any(.messages[].rich_message.blocks[]?; .type == \"video\")' >/dev/null"
        )
        response = json.loads(machine.succeed(f"curl -fsS {shlex.quote(messages)}"))
        videos = [
            block["video"]
            for message in response["messages"]
            for block in message.get("rich_message", {}).get("blocks", [])
            if block["type"] == "video"
        ]
        assert len(videos) == 1, response
        output = f"/tmp/{name}-uploaded.mp4"
        machine.succeed(
            f"curl -fsS {api}/debug/files/{videos[0]['file_id']} -o {output}"
        )
        probe = json.loads(
            machine.succeed(
                "ffprobe -v error -select_streams v:0 -show_entries "
                f"stream=codec_name:format=duration -of json {output}"
            )
        )
        assert probe["streams"][0]["codec_name"] == "h264", probe
        assert abs(float(probe["format"]["duration"]) - 4) < 0.1, probe
        assert size(output) <= ceiling
        return output

    with subtest("compatible video within the target passes through unchanged"):
        source = f"{media_dir}/passthrough.mp4"
        assert size(source) < target
        output = upload("passthrough", 1001)
        machine.succeed(f"cmp {source} {output}")

    with subtest(
        "compatible video above the target is compressed below the upload ceiling"
    ):
        source = f"{media_dir}/compress.mp4"
        assert target < size(source) < ceiling
        output = upload("compress", 1002)
        assert size(output) < size(source) / 2

    with subtest("small HEVC source uses a size budget and its overshoot is accepted"):
        source = f"{media_dir}/convert.mp4"
        assert size(source) < target
        output = upload("convert", 1003)
        assert target < size(output) < target * 1.5
