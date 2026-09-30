# A post is a rich message: its media sit in blocks (a gallery in one collage)
# and its text is spread over paragraph, details and footer blocks. Classic
# messages are still read for the fallback path.

MEDIA_COUNT_JQ = (
    "[.messages[] | if .rich_message then "
    '(.rich_message | .. | objects | select(.type? == "photo" or .type? == "video")) '
    "else select(.video != null or .photo != null) end] | length"
)


def _holder_media(holder):
    if holder.get("video"):
        return ("video", holder["video"])
    if holder.get("photo"):
        return ("photo", holder["photo"][-1])
    return None


def message_media(message):
    if not message.get("rich_message"):
        media = _holder_media(message)
        return [] if media is None else [media]

    media = []
    blocks = list(message["rich_message"].get("blocks") or [])
    while blocks:
        block = blocks.pop(0)
        if block.get("type") == "collage":
            blocks[0:0] = block.get("blocks") or []
        elif _holder_media(block) is not None:
            media.append(_holder_media(block))
    return media


def message_video(message):
    for kind, media in message_media(message):
        if kind == "video":
            return media
    return None


def _rich_texts(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [text for item in value for text in _rich_texts(item)]
    if isinstance(value, dict):
        return [
            text
            for key in ("text", "summary", "blocks")
            if key in value
            for text in _rich_texts(value[key])
        ]
    return []


def message_text(message):
    if message.get("rich_message"):
        return "".join(_rich_texts(message["rich_message"]["blocks"]))
    return message.get("caption") or ""
