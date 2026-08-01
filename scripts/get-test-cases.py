#!/usr/bin/env python3
"""List media-producing test cases from gallery-dl and yt-dlp."""

import argparse
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


def emit_gallery_dl_cases(gallery_dl_results):
    """Emit gallery-dl cases expected to yield images or videos."""
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
                print(
                    json.dumps(
                        {
                            "source": "gallery-dl",
                            "service": site,
                            "kind": GALLERY_DL_MEDIA[extractor_key],
                            "url": case["#url"],
                        }
                    )
                )


def emit_yt_dlp_cases(gen_extractor_classes):
    """Emit yt-dlp cases expected to yield videos."""
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
                print(
                    json.dumps(
                        {
                            "source": "yt-dlp",
                            "service": extractor_key.removesuffix("VM")
                            .removesuffix("Story")
                            .lower(),
                            "kind": "video",
                            "url": url,
                        }
                    )
                )


def main():
    """Load both upstream test corpora and write matching cases as JSONL."""
    args = parse_args()
    add_source_paths(args)
    gallery_dl_results, gen_extractor_classes = load_upstreams()
    emit_gallery_dl_cases(gallery_dl_results)
    emit_yt_dlp_cases(gen_extractor_classes)


if __name__ == "__main__":
    main()
