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
