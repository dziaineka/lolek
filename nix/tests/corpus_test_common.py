import hashlib
import json
from urllib.parse import quote


IMAGE_FIXTURES = (
    "landscape.jpg",
    "portrait.jpg",
    "square.jpg",
)
VIDEO_FIXTURES = (
    "landscape.mp4",
    "portrait.mp4",
)


def load_cases(path):
    with open(path, encoding="utf-8") as corpus_file:
        return [json.loads(line) for line in corpus_file if line.strip()]


def cases_by_url(path):
    return {case["url"]: case for case in load_cases(path)}


def find_case(path, arguments):
    by_url = cases_by_url(path)

    for argument in reversed(arguments):
        if argument in by_url:
            return by_url[argument]

    raise ValueError("command does not contain a corpus URL")


def scenario(case):
    selector = int(hashlib.sha256(case["url"].encode("utf-8")).hexdigest(), 16)

    if "gallery-dl" not in case["sources"]:
        return {
            "route": "yt-dlp",
            "fixtures": [VIDEO_FIXTURES[selector % len(VIDEO_FIXTURES)]],
        }

    if case["kinds"] == ["image"]:
        fixtures = [IMAGE_FIXTURES[selector % len(IMAGE_FIXTURES)]]
    elif case["kinds"] == ["video"]:
        fixtures = [VIDEO_FIXTURES[selector % len(VIDEO_FIXTURES)]]
    else:
        fixtures = (
            [IMAGE_FIXTURES[selector % len(IMAGE_FIXTURES)]],
            [VIDEO_FIXTURES[selector % len(VIDEO_FIXTURES)]],
            [IMAGE_FIXTURES[0], IMAGE_FIXTURES[1]],
            [IMAGE_FIXTURES[2], VIDEO_FIXTURES[0]],
        )[selector % 4]

    return {"route": "gallery-dl", "fixtures": fixtures}


def fixture_kind(fixture):
    if fixture.endswith(".mp4"):
        return "video"
    return "photo"


def fixture_url(origin, case_id, fixture):
    return "%s/media/%s/%s" % (
        origin.rstrip("/"),
        quote(case_id, safe=""),
        quote(fixture, safe=""),
    )
