# Agent Instructions for Lolek

This document provides guidance for AI coding agents working in the Lolek codebase.

## Project Overview

**Lolek** is an Elixir/OTP Telegram bot that downloads videos from URLs using yt-dlp, converts them with ffmpeg, and uploads them to Telegram.

- **Language**: Elixir (see version in `.tool-versions`)
- **Framework**: OTP Application with ExGram (Telegram bot framework)
- **Build Tool**: Mix
- **Version Manager**: mise (see `.tool-versions`)

## Build, Test & Quality Commands

### Basic Commands

```bash
# Install dependencies
mix deps.get

# Compile project
mix compile

# Run application
mix run --no-halt

# Interactive shell
iex -S mix
```

### Testing

```bash
# Run all tests
mix test

# Run single test file
mix test test/lolek_test.exs

# Run specific test by line number
mix test test/lolek_test.exs:10

# Run tests with coverage
mix test --cover
```

### Quality Checks (Required Before Committing)

```bash
# Run all quality checks (recommended)
mix check

# Individual tools
mix format                # Format code (auto-fix)
mix format --check-formatted  # Check without modifying
mix credo                 # Static code analysis
mix credo --strict        # Strict mode
mix dialyzer              # Type checking (slow first run)
mix doctor                # Documentation coverage check
mix deps.audit            # Security vulnerability scan
mix hex.outdated          # Check for outdated dependencies
```

### Documentation

```bash
mix docs                  # Generate HTML documentation in doc/
```

### Production Release

```bash
MIX_ENV=prod mix release  # Build production release
```

## Code Style Guidelines

### Module Documentation

- **REQUIRED**: Every module must have a `@moduledoc` docstring
- **REQUIRED**: All exception modules must have `@moduledoc`
- Keep module docs concise (1-2 sentences describing purpose)

```elixir
defmodule Lolek.Handler do
  @moduledoc """
  This module is responsible for handling the bot's commands and messages.
  """
  # ...
end
```

### Type Specifications

- **REQUIRED**: 100% type spec coverage on all public functions
- **REQUIRED**: Custom types for struct definitions (`@type`)
- Use `@spec` for all public functions (`def`)
- Private functions (`defp`) should also have specs when complex
- Use tagged tuples for return types: `{:ok, value} | {:error, reason}`

```elixir
@type file_state ::
        {:ready_to_telegram, String.t()}
        | {:compressed, String.t()}
        | {:downloaded, String.t()}
        | {:new_file, String.t()}

@spec download(String.t(), file_state()) :: {:ok, file_state()} | {:error, String.t()}
def download(url, file_state) do
  # implementation
end
```

### Imports & Aliases

- Don't use `alias` to shorten module names, prefer using full module names for clarity
- Avoid `import` unless necessary (ExGram macros are exception)
- Group requires/aliases at top of module after `@moduledoc`

```elixir
defmodule Lolek.Example do
  @moduledoc """
  Example module.
  """
  require Logger


  # module code
end
```

## Architecture Patterns

### State Machine Pattern

File processing uses tagged tuples for state transitions:

```
:new_file → :downloaded → :compressed → :sent_to_telegram_at_first → :ready_to_telegram
```

### Rich Message Posts

Lolek sends each post as one Telegram rich message (`sendRichMessage`, Bot API 10.1+). The message looks like the source post.

- `Lolek.Post` is the source post: author, text with link facets, date, counters, quoted post, parent post, link card. `Lolek.SourceMetadata` caches it in `post.json` in the URL cache folder.
- Metadata sources, highest priority first: the public Bluesky API (`Lolek.Post.Bluesky`), gallery-dl JSON (`Lolek.Post.GalleryDl`), page data (Threads posts in `Lolek.Post.Threads`, YouTube posts), yt-dlp JSON (`Lolek.Post.YtDlp`). `Lolek.Post.merge/2` combines them.
- `Lolek.Post.Enricher` fetches the quoted tweet and the parent tweet with gallery-dl.
- `Lolek.RichPost` builds the rich message from `InputRichBlock*` structs (not HTML or Markdown). The layout changes per platform (collage for X, Bluesky, Threads, and Facebook; slideshow for Instagram and TikTok). Uploads are `{:file_content, ...}` or `file://` sources in the media blocks; ExGram sends them as multipart parts.
- After the send, Lolek reads the file_ids of its uploads from the `rich_message` blocks of the response (at the block positions that `Lolek.RichPost.build/3` returns) for the cache.

### Supervised Processes

Application structure (see `lib/lolek/application.ex`):

- ExGram bot
- Lolek.Handler (command handler)
- Lolek.FileCleaner (cleanup GenServer)

## Environment Configuration

All configuration is read directly from environment variables in `config/runtime.exs` using `System.get_env/2` (with defaults) and `System.fetch_env!/1` (for required vars). There is no dotenv file loading at runtime — `config/.env.default` exists as a reference for default values only.

**Policy:**
- All parsing, type validation, and cross-parameter checks happen at startup in `config/runtime.exs`. A bad value raises a descriptive error immediately.
- In `lib/` code, always use `Application.fetch_env!(:lolek, key)` — every key is guaranteed to be present and correctly typed after startup.
- Never use `System.get_env` inside `lib/` modules.
- Avoid using `Application.get_env` with defaults in `lib/` code, as it can mask configuration issues.

Key environment variables:

- `LOLEK_BOT_TOKEN` - Telegram bot token (required unless `LOLEK_BOT_TOKEN_FILE` is set)
- `LOLEK_BOT_TOKEN_FILE` - Path to file containing the bot token (takes precedence over `LOLEK_BOT_TOKEN`)
- `LOLEK_DOWNLOAD_DIR_PATH` - Download directory (default: `./downloads`)
- `LOLEK_HW_ACCELERATION` - H.264 encoder backend (`none`, `vaapi`, or `qsv`; default: `none`)
- `LOLEK_HW_DEVICE` - Render device for hardware acceleration (default: `/dev/dri/renderD128`)
- `LOLEK_POST_SOURCE_CAPTION` - Show the source post details in the rich message (default: `true`)
- `LOLEK_POST_REQUESTER_CAPTION` - Show the requester and processing time line (default: `false`)
- `LOLEK_MAX_GALLERY_MEDIA` - Maximum media files in one post, 1 to 50 (default: `50`)
- Various size/duration limits for compression logic

## External Dependencies

- **yt-dlp**: Video downloading (see `.tool-versions` for pinned version)
- **ffmpeg/ffprobe**: Video processing and analysis; hardware encoding supports VAAPI and Intel QSV when the ffmpeg build and host render device support it
- **Python3**: Required by yt-dlp

All available in Docker container; local development runs via Docker Compose.

## Testing Notes

Tests live in `test/`. Run with `mix test` or `mix check` (which includes the full suite).

## Git Workflow

- Run `mix check` before committing to catch issues early
- All checks must pass for clean commits
