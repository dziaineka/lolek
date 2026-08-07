import json
import os
import sys
from pathlib import Path
from urllib.request import Request, urlopen

import corpus_test_common

CORPUS_PATH = os.environ["LOLEK_TEST_CORPUS_PATH"]
ORIGIN = os.environ["LOLEK_TEST_CORPUS_ORIGIN"]


def post_event(payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = Request(
        f"{ORIGIN}/debug/events",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request) as response:
        response.read()


def download(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with urlopen(url) as response, path.open("wb") as output_file:
        while chunk := response.read(64 * 1024):
            output_file.write(chunk)


def output_path(arguments):
    try:
        return Path(arguments[arguments.index("-o") + 1])
    except (ValueError, IndexError) as error:
        raise ValueError("yt-dlp command does not contain -o PATH") from error


def main():
    arguments = sys.argv[1:]
    case = corpus_test_common.find_case(CORPUS_PATH, arguments)

    if "--dump-single-json" in arguments:
        post_event({"type": "metadata", "case_id": case["id"]})
        print(
            json.dumps(
                {
                    "title": f"Corpus fixture {case['id']}",
                    "description": f"Corpus fixture for {case['id']}",
                }
            )
        )
        return

    if "--simulate" in arguments:
        post_event({"type": "formats", "case_id": case["id"]})
        print(json.dumps([{"format_id": "corpus-fixture"}]))
        return

    case_scenario = corpus_test_common.scenario(case)
    if case_scenario["route"] != "yt-dlp":
        raise ValueError(f"unexpected yt-dlp download for {case['id']}")

    fixture = case_scenario["fixtures"][0]
    post_event({"type": "download", "case_id": case["id"], "fixture": fixture})
    download(
        corpus_test_common.fixture_url(ORIGIN, case["id"], fixture),
        output_path(arguments),
    )


if __name__ == "__main__":
    main()
