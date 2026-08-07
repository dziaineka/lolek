"""Classify volatile downloader diagnostics into stable failure reasons."""

from __future__ import annotations

import re

from lolek_corpus.model import (
    TERMINAL_NO_URL,
    TERMINAL_NO_USABLE_MEDIA_FILES,
    TERMINAL_NO_VIDEO_FORMATS,
    TERMINAL_OK,
    FailureReason,
    TerminalResult,
)

RATE_LIMIT_PATTERN = re.compile(
    r"(?:HTTP (?:Error )?429|Too Many Requests|rate[ -]?limit)", re.IGNORECASE
)
FAILURE_REASON_PATTERNS = (
    (
        FailureReason.AUTHENTICATION_REQUIRED,
        re.compile(
            r"(?:only available for registered users|"
            r"Instagram API is not granting access|"
            r"Instagram sent an empty media response|"
            r"HTTP redirect to login page|"
            r"need to log in|"
            r"authenticated cookies needed|"
            r"not authorized to view this protected tweet|"
            r"AuthRequired: Protected Tweet)",
            re.IGNORECASE,
        ),
    ),
    (
        FailureReason.ACCESS_BLOCKED,
        re.compile(r"IP address is blocked from accessing this post", re.IGNORECASE),
    ),
    (
        FailureReason.STALE_REDIRECT,
        re.compile(r"Unsupported URL: https://www\.tiktok\.com/\?_r=1", re.IGNORECASE),
    ),
    (
        FailureReason.EXTRACTOR_ERROR,
        re.compile(r"Cannot parse data; please report this issue", re.IGNORECASE),
    ),
    (
        FailureReason.STALE_MEDIA,
        re.compile(
            r"(?:HTTP Error 500: Domain Not Found|"
            r"HTTP Error 404: Not Found|"
            r"HttpError: '404 Not Found'|"
            r"Tweet unavailable \('Suspended'\)|"
            r"ERROR: \[twitter\] \d+: Suspended)",
            re.IGNORECASE,
        ),
    ),
    (
        FailureReason.DOWNLOAD_OUTPUT_MISSING,
        re.compile(r'result=error:"File not found"', re.IGNORECASE),
    ),
    (
        FailureReason.NO_VIDEO_FORMATS,
        re.compile(r"No video formats found", re.IGNORECASE),
    ),
    (
        FailureReason.UNSUPPORTED_MEDIA,
        re.compile(r"ERROR: Unsupported URL:", re.IGNORECASE),
    ),
)


def classify_failure_reason(
    terminal_result: TerminalResult, case_log: str
) -> FailureReason | None:
    """Normalize volatile downloader diagnostics into a stable reason code."""
    if terminal_result in {TERMINAL_OK, TERMINAL_NO_URL}:
        return None
    if RATE_LIMIT_PATTERN.search(case_log):
        return FailureReason.RATE_LIMITED
    if ":too_big_media" in case_log:
        return FailureReason.DEFAULT_MEDIA_LIMIT
    for reason, pattern in FAILURE_REASON_PATTERNS:
        if pattern.search(case_log):
            return reason
    if terminal_result == TERMINAL_NO_USABLE_MEDIA_FILES:
        return FailureReason.NO_USABLE_MEDIA
    if terminal_result == TERMINAL_NO_VIDEO_FORMATS:
        return FailureReason.NO_VIDEO_FORMATS
    return FailureReason.UNCLASSIFIED
