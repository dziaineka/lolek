def test_private_media(
    machine,
    subtest,
    api,
    token,
    gallery_url,
):
    """Exercise private media through the running service and Telegym HTTP API."""

    import json
    import shlex
    from urllib.parse import parse_qs, urlparse

    def get(path):
        return json.loads(machine.succeed(f"curl -fsS {shlex.quote(api + path)}"))

    def post(path, payload):
        return json.loads(
            machine.succeed(
                "curl -fsS -H 'Content-Type: application/json' --data "
                f"{shlex.quote(json.dumps(payload))} {shlex.quote(api + path)}"
            )
        )

    def wait_for(path, predicate):
        machine.wait_until_succeeds(
            f"curl -fsS {shlex.quote(api + path)} | jq -e {shlex.quote(predicate)} >/dev/null"
        )

    def messages(chat_id):
        return get(f"/debug/messages/{token}?chat_id={chat_id}")["messages"]

    def inject(chat_id, text, chat_type="private"):
        result = post(
            "/debug/inject/update",
            {
                "token": token,
                "chat_id": chat_id,
                "user_id": 9001,
                "chat_type": chat_type,
                "text": text,
            },
        )
        assert result["ok"] and result["queued"], result

    with subtest("redeem a group gallery privately after restarting the service"):
        inject(-8001, gallery_url, "supergroup")
        wait_for(
            f"/debug/messages/{token}?chat_id=-8001",
            'any(.messages[]; .reply_markup.inline_keyboard[0][0].text == "Get media privately")',
        )
        edited = next(
            message for message in messages(-8001) if message.get("reply_markup")
        )
        button = edited["reply_markup"]["inline_keyboard"][0][0]
        payload = parse_qs(urlparse(button["url"]).query)["start"][0]
        post_message = next(
            message for message in messages(-8001) if message.get("rich_message")
        )
        gallery = next(
            block["blocks"]
            for block in post_message["rich_message"]["blocks"]
            if block["type"] == "collage"
        )
        assert [block["type"] for block in gallery] == ["video", "photo"], gallery
        video_id = gallery[0]["video"]["file_id"]
        photo_id = gallery[1]["photo"][-1]["file_id"]

        machine.succeed("systemctl restart lolek.service")
        machine.wait_for_unit("lolek.service")
        inject(9001, "/start " + payload)
        wait_for(
            f"/debug/requests/{token}",
            'any(.requests[]; .method == "deleteMessage" and '
            '(.parameters.chat_id | tostring) == "9001" and .status == 200)',
        )

        delivered = sorted(messages(9001), key=lambda message: message["message_id"])
        assert len(delivered) == 2, delivered
        assert delivered[0]["video"]["file_id"] == video_id, delivered
        assert delivered[1]["photo"][-1]["file_id"] == photo_id, delivered
        assert delivered[0]["media_group_id"]
        assert delivered[0]["media_group_id"] == delivered[1]["media_group_id"]
        assert all(
            not message.get("caption") and not message.get("rich_message")
            for message in delivered
        )
