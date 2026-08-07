# Testing

## Upstream extractor test cases

List media-producing gallery-dl and yt-dlp test cases using Nix:

```console
nix run .#get-test-cases
```

Without Nix, if gallery-dl's test package and yt-dlp are already importable, run:

```console
python3 scripts/get-test-cases.py
```

Otherwise, check out both upstream projects, ensure the gallery-dl runtime
dependencies are available, and supply their paths:

```console
PYTHONPATH=../gallery-dl:../yt-dlp python3 scripts/get-test-cases.py
```

The equivalent `--gallery-dl-source` and `--yt-dlp-source` options are also
available. The command writes one JSON object per line to standard output.
Rows use this schema:

```json
{"id":"youtube-b1cce5c7b928cc23","service":"youtube","url":"https://www.youtube.com/watch?v=example","sources":["yt-dlp"],"kinds":["video"]}
```

The ID is `<service>-<digest>`, where `digest` is the first 16 hexadecimal
characters of the SHA-256 hash of the exact URL string. It is deterministic,
unlike a generated UUID: the same service and URL keep the same ID across
runs. Changing the URL spelling or query string intentionally creates a new
case. Duplicate exact URLs are merged, including their `sources` and `kinds`.

The package check rejects malformed records, duplicate URLs or IDs, and the
unlikely event of a truncated digest collision.

## Isolated corpus integration test

Run the complete upstream corpus through the packaged bot in an isolated
NixOS container:

```console
nix build .#checks.x86_64-linux.nixos-corpus -L
```

The test starts Lolek, Telegym, and a local media HTTP origin. Fake
`gallery-dl` and `yt-dlp` commands accept only exact URLs from the generated
corpus and fetch deterministic image and video fixtures from that origin.
For every URL accepted by the default allowlist, the test verifies the
Telegram media type and SHA-256 hash of every uploaded file. It also covers
single photos, single videos, photo albums, mixed-media albums, yt-dlp
fallback, explicit allowlist rejections, extractor routing, and cache reuse.

This test validates corpus recognition and Lolek's complete media pipeline
without external network access. It deliberately does not validate that the
real upstream extractors can still download the live URLs; that remains a
separate, network-dependent concern.

## Live corpus tests

Run selected upstream cases through the packaged bot and Telegym while using
the real `gallery-dl`, `yt-dlp`, and `ffmpeg`:

```console
nix run .#live-corpus -- --case coub-f7f8bd840092a5ad
```

Use the check apps for complete regression sweeps:

```console
nix run .#live-corpus-check -- --report no-gallery-report.json
nix run .#live-corpus-gallery-check -- --report gallery-report.json
```

The `no-gallery` profile disables gallery downloads and covers yt-dlp cases
plus default allowlist rejections. The `gallery` profile enables gallery-dl
with yt-dlp fallback and covers the full reviewed corpus. Both profiles use a
temporary home directory, supply no cookies or ambient downloader
configuration, and exercise Lolek's default settings.

A full gallery check takes roughly 10 minutes with the stability-oriented
default pacing. The runner interleaves services and applies service-local
delays with deterministic jitter. Use repeatable `--service` or `--case`
filters and `--limit` for a smaller sweep. Run
`nix run .#live-corpus -- --help` for all controls.

Bundled profile policies record exact successful media shapes and reviewed
anonymous extractor failures. The check apps retry an unexpected result once
before confirming it. Known failures and intermittent results remain
non-fatal; repeatable regressions and inconclusive runs return nonzero.

For each successful first pass, the runner validates the Telegym capture with
`ffprobe`, its size and Telegram-compatible H.264/MP4 shape, and Lolek's cache
manifest. It then injects the same URL again and requires reuse of the same
Telegram file ID without another upload. Between cases it clears Telegym's
captured messages and files and removes only that case's temporary Lolek
cache. A host lock prevents concurrent live sweeps.

Use `--report path.json` for a structured result report. Process logs and
temporary downloads are removed on exit unless `--keep-work-dir` is passed.
The `Live corpus` CI job runs both profiles sequentially and uploads their
JSON reports.

The runner is also an independent Python project under `corpus/`. Its
[README](corpus/README.md) documents locked `uv` development and conventional
editable `pip` installation. Nix builds the same wheel with:

```console
nix build .#corpus
```
