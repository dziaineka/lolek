# Agent Instructions for Lolek

This document provides guidance for AI coding agents working in the Lolek codebase.

## Project Overview

**Lolek** is an Elixir/OTP Telegram bot that downloads videos from URLs using yt-dlp, converts them with ffmpeg, and uploads them to Telegram.

- **Language**: Elixir (see version in `.tool-versions`)
- **Framework**: OTP Application with ExGram (Telegram bot framework)
- **Build Tool**: Mix
- **Version Manager**: asdf (see `.tool-versions`)

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

### 1. Module Documentation

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

### 2. Type Specifications

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

### 3. Naming Conventions

- **Modules**: PascalCase (e.g., `Lolek.Downloader`)
- **Functions**: snake_case (e.g., `get_file_state/1`)
- **Variables**: snake_case (e.g., `file_path`, `output_path`)
- **Atoms**: snake_case (e.g., `:new_file`, `:downloaded`)
- **Files**: snake_case matching module name (e.g., `file_cleaner.ex` for `Lolek.FileCleaner`)

### 5. Imports & Aliases

- Use `require Logger` for logging functions
- Avoid using `alias` to shorten module names, prefer using full module names for clarity
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

### Supervised Processes

Application structure (see `lib/lolek/application.ex`):

- ExGram bot
- Lolek.Handler (command handler)
- Lolek.FileCleaner (cleanup GenServer)

## Environment Configuration

Configuration is in `config/runtime.exs` and loaded from:

- `config/.env.default` (defaults)
- `config/.env` (local overrides, gitignored)

Key environment variables:

- `LOLEK_BOT_TOKEN` - Telegram bot token (required)
- `LOLEK_DOWNLOAD_DIR_PATH` - Download directory (default: `./downloads`)
- `LOLEK_HW_ACCELERATION` - H.264 encoder backend (`none` or `vaapi`; default: `none`)
- `LOLEK_HW_DEVICE` - Render device for hardware acceleration (default: `/dev/dri/renderD128`)
- Various size/duration limits for compression logic

## External Dependencies

- **yt-dlp**: Video downloading (v2025.12.08)
- **ffmpeg/ffprobe**: Video processing and analysis
- **Python3**: Required by yt-dlp

All available in Docker container; local development runs via Docker Compose.

## Testing Notes

No tests currently.

## Git Workflow

- Run `mix check` before committing to catch issues early
- All checks must pass for clean commits
