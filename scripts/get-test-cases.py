#!/usr/bin/env python3
"""List media-producing test cases from gallery-dl and yt-dlp."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys


GALLERY_DL_MEDIA = {
    ("tiktok", "post"): "image_or_video",
    ("tiktok", "vmpost"): "image_or_video",
    ("instagram", "post"): "image_or_video",
    ("instagram", "stories"): "image_or_video",
    ("twitter", "tweet"): "image_or_video",
    ("facebook", "photo"): "image",
    ("facebook", "video"): "video",
}

YT_DLP_VIDEO_EXTRACTORS = {
    "TikTok",
    "TikTokVM",
    "Instagram",
    "InstagramStory",
    "Twitter",
    "Facebook",
    "Youtube",
    "Coub",
}


def parse_args():
    """Parse paths to upstream source checkouts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--gallery-dl-source",
        type=Path,
        help="gallery-dl source tree containing test/results.py",
    )
    parser.add_argument(
        "--yt-dlp-source",
        type=Path,
        help="yt-dlp source tree containing the yt_dlp package",
    )
    return parser.parse_args()


def add_source_paths(args):
    """Make explicitly supplied upstream source trees importable."""
    paths = [args.gallery_dl_source, args.yt_dlp_source]
    sys.path[:0] = [str(path.resolve()) for path in paths if path is not None]


def load_upstreams():
    """Import upstream test APIs with a useful error for source-less runs."""
    os.environ.setdefault("YTDLP_NO_LAZY_EXTRACTORS", "true")

    try:
        from test import results as gallery_dl_results
        from yt_dlp.extractor import gen_extractor_classes
    except ImportError as error:
        raise SystemExit(
            "Unable to import upstream tests. Pass --gallery-dl-source and "
            "--yt-dlp-source, or add both source trees to PYTHONPATH."
        ) from error

    return gallery_dl_results, gen_extractor_classes


def gallery_dl_cases(gallery_dl_results):
    """Yield gallery-dl cases expected to produce images or videos."""
    for site in sorted({site for site, _subcategory in GALLERY_DL_MEDIA}):
        for case in gallery_dl_results.category(site):
            extractor = case["#class"]
            extractor_key = (extractor.category, extractor.subcategory)

            if (
                extractor_key in GALLERY_DL_MEDIA
                and not case.get("#skip")
                and not case.get("#fail")
                and "#exception" not in case
                and case.get("#count") != 0
                and case.get("#results") != ()
            ):
                yield {
                    "source": "gallery-dl",
                    "service": site,
                    "kind": GALLERY_DL_MEDIA[extractor_key],
                    "url": case["#url"],
                }


def yt_dlp_cases(gen_extractor_classes):
    """Yield yt-dlp cases expected to produce videos."""
    for extractor in gen_extractor_classes():
        extractor_key = extractor.ie_key()
        if extractor_key not in YT_DLP_VIDEO_EXTRACTORS:
            continue

        for case in extractor.get_testcases(include_onlymatching=False):
            url = case["url"]
            info = case.get("info_dict", {})

            # Lolek allows YouTube Shorts, not general YouTube URLs.
            if extractor_key == "Youtube" and "/shorts/" not in url:
                continue

            if not case.get("skip") and info.get("ext"):
                yield {
                    "source": "yt-dlp",
                    "service": extractor_key.removesuffix("VM")
                    .removesuffix("Story")
                    .lower(),
                    "kind": "video",
                    "url": url,
                }


def case_id(service, url):
    """Return a readable deterministic identifier for an exact URL."""
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()
    return f"{service}-{digest[:16]}"


def normalize_cases(cases):
    """Deduplicate URL variants and combine their upstream provenance."""
    by_url = {}

    for case in cases:
        url = case["url"]
        existing = by_url.setdefault(
            url,
            {
                "id": case_id(case["service"], url),
                "service": case["service"],
                "sources": set(),
                "kinds": set(),
                "url": url,
            },
        )

        if existing["service"] != case["service"]:
            raise ValueError(
                f"URL appears under multiple services: {url!r}: "
                f"{existing['service']!r}, {case['service']!r}"
            )

        existing["sources"].add(case["source"])
        existing["kinds"].add(case["kind"])

    normalized = []
    identifiers = set()

    for case in sorted(
        by_url.values(), key=lambda item: (item["service"], item["url"])
    ):
        if case["id"] in identifiers:
            raise ValueError(f"Generated duplicate case ID: {case['id']}")

        identifiers.add(case["id"])
        case["sources"] = sorted(case["sources"])
        case["kinds"] = sorted(case["kinds"])
        normalized.append(case)

    return normalized


def emit_cases(cases):
    """Write normalized cases as JSON Lines."""
    for case in cases:
        print(json.dumps(case))


def main():
    """Load both upstream test corpora and write matching cases as JSONL."""
    args = parse_args()
    add_source_paths(args)
    gallery_dl_results, gen_extractor_classes = load_upstreams()
    cases = [
        *gallery_dl_cases(gallery_dl_results),
        *yt_dlp_cases(gen_extractor_classes),
    ]
    emit_cases(normalize_cases(cases))


if __name__ == "__main__":
    main()
