import json
import os
import sys
from pathlib import Path
from urllib.request import Request, urlopen

import corpus_test_common

CORPUS_PATH = os.environ["LOLEK_TEST_CORPUS_PATH"]
ORIGIN = os.environ["LOLEK_TEST_CORPUS_ORIGIN"]


def command_arguments(arguments):
    value_options = {"--cookies", "--config", "--dest", "--range", "-o"}
    destination = None
    positionals = []
    index = 0

    while index < len(arguments):
        argument = arguments[index]

        if argument in value_options:
            index += 1
            if index >= len(arguments):
                raise ValueError(f"missing value for {argument}")
            if argument == "--dest":
                destination = arguments[index]
        elif not argument.startswith("-"):
            positionals.append(argument)

        index += 1

    if destination is None:
        raise ValueError("gallery-dl command does not contain --dest")
    if not positionals:
        raise ValueError("gallery-dl command does not contain a URL")

    return Path(destination), positionals[-1]


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
    with urlopen(url) as response, path.open("wb") as output_file:
        while chunk := response.read(64 * 1024):
            output_file.write(chunk)


def main():
    destination, url = command_arguments(sys.argv[1:])
    case = corpus_test_common.find_case(CORPUS_PATH, [url])
    case_scenario = corpus_test_common.scenario(case)
    handled = case_scenario["route"] == "gallery-dl"
    post_event({"type": "gallery", "case_id": case["id"], "handled": handled})

    if not handled:
        return

    target_dir = destination / case["service"] / case["id"]
    target_dir.mkdir(parents=True, exist_ok=True)

    for index, fixture in enumerate(case_scenario["fixtures"], start=1):
        target = target_dir / f"{index:02d}-{fixture}"
        download(corpus_test_common.fixture_url(ORIGIN, case["id"], fixture), target)

    metadata = {
        "content": f"Corpus fixture for {case['id']}",
        "title": f"Corpus fixture {case['id']}",
    }
    (target_dir / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")


if __name__ == "__main__":
    main()
