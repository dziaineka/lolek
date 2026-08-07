# Lolek live corpus runner

`lolek-corpus` drives a Lolek release through Telegym using live extractor
URLs. It validates Telegram uploads, cache manifests, and cache replay while
recording stable regression verdicts for volatile external services.

The package has no third-party runtime dependencies. It bundles reviewed
expectation policies for its runner profiles and expects Lolek, Telegym, and
`ffprobe` executables supplied through command-line options.

## Develop with uv

```console
uv sync --extra dev
uv run python -m unittest discover -s tests
uv run ty check src tests
uv run ruff format --check .
uv run ruff check .
```

## Develop with pip

```console
python3.13 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]'
.venv/bin/python -m unittest discover -s tests
.venv/bin/ty check src tests
.venv/bin/ruff format --check .
.venv/bin/ruff check .
```

After installation, `live-corpus --help` documents the runner interface.
The corpus, Lolek release, Telegym mock, and `ffprobe` paths are explicit
inputs. `--expectations` can replace the bundled policy when needed:

```console
live-corpus \
  --corpus corpus.jsonl \
  --lolek /path/to/lolek \
  --telegym /path/to/telegym-mock \
  --ffprobe /path/to/ffprobe \
  --case coub-f7f8bd840092a5ad
```

The default `no-gallery` profile exercises the yt-dlp corpus with gallery
downloads disabled. Use `--profile gallery --probe` to observe gallery-dl
cases which do not yet have reviewed expectations.

From the Lolek repository, Nix supplies all executable inputs. The check apps
retry unexpected extractor results once before confirming a regression:

```console
nix run .#live-corpus-check -- --report no-gallery-report.json
nix run .#live-corpus-gallery-check -- --report gallery-report.json
```

The default pacing is chosen for stability. Expect a full gallery run to take
roughly 10 minutes.
