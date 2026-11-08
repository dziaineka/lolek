start_compose:
	docker compose up --build

NAME   := skaborik/lolek_bot
TAG    := $$(git describe --tags --abbrev=0)
IMG    := ${NAME}:${TAG}
LATEST := ${NAME}:latest

build:
	@docker build -t ${IMG} .
	@docker build -t ${LATEST} .

push:
	@docker push ${IMG}
	@docker push ${LATEST}

check:
	mix check

# -L prints the build logs; --show-trace prints the full trace of evaluation errors.
# Only the checks of the current system run (the NixOS VM checks need Linux).
nix-check:
	nix flake check -L --show-trace

format:
	mix format

# Live corpus: test Lolek with the real gallery-dl, yt-dlp, and ffmpeg against
# live media services, through a local Telegym. These targets are not in CI.
# Give runner options with ARGS, for example:
#   make live-corpus ARGS="--case coub-f7f8bd840092a5ad"
#   make live-corpus-gallery ARGS="--service twitter --limit 4"
ARGS ?=

.PHONY: live-corpus-test live-corpus live-corpus-check live-corpus-gallery live-corpus-gallery-check
# Run all live corpus checks (both profiles) and show one summary. The JSON
# reports are in live-corpus-reports/. A full run takes about 15 minutes.
live-corpus-test:
	scripts/live-corpus-test.sh $(ARGS)

live-corpus:
	nix run .#live-corpus -- $(ARGS)

live-corpus-check:
	nix run .#live-corpus-check -- $(ARGS)

live-corpus-gallery:
	nix run .#live-corpus-gallery -- $(ARGS)

live-corpus-gallery-check:
	nix run .#live-corpus-gallery-check -- $(ARGS)

# Manual test with Telegym (see TESTING.md). Use three terminals:
#   make telegym-mock                     # 1. the Telegram Bot API mock
#   make telegym-bot                      # 2. Lolek connected to the mock
#   make telegym-send URL=https://...     # 3. send a URL as a user message
#   make telegym-messages                 #    show the sent rich messages
# The browser chat is at http://127.0.0.1:$(TELEGYM_PORT)/debug/chat.
TELEGYM_PORT ?= 5678
TELEGYM_URL := http://127.0.0.1:$(TELEGYM_PORT)
TELEGYM_TOKEN ?= 1234567890:telegym_default_mock_token_xxxxxxxx
TELEGYM_CHAT_ID ?= 1234
TELEGYM_DOWNLOAD_DIR ?= /tmp/lolek-telegym

.PHONY: telegym-mock telegym-bot telegym-send telegym-messages telegym-clear
telegym-mock:
	nix shell .#telegym -c telegym-mock -listen 127.0.0.1:$(TELEGYM_PORT) -metrics-listen ""

telegym-bot:
	mkdir -p $(TELEGYM_DOWNLOAD_DIR)
	LOLEK_BOT_TOKEN=$(TELEGYM_TOKEN) \
	LOLEK_TELEGRAM_BASE_URL=$(TELEGYM_URL) \
	LOLEK_DOWNLOAD_DIR_PATH=$(TELEGYM_DOWNLOAD_DIR) \
	LOLEK_GALLERY_DOWNLOAD_ENABLED=$${LOLEK_GALLERY_DOWNLOAD_ENABLED:-true} \
	mix run --no-halt

telegym-send:
	@test -n "$(URL)" || { echo 'Usage: make telegym-send URL=https://...'; exit 1; }
	@jq -n --arg token '$(TELEGYM_TOKEN)' --arg url '$(URL)' --argjson chat $(TELEGYM_CHAT_ID) \
		'{token: $$token, chat_id: $$chat, username: "manual_test", first_name: "Manual Test", text: $$url}' | \
		curl -fsS -H 'Content-Type: application/json' --data @- $(TELEGYM_URL)/debug/inject/update | jq .

telegym-messages:
	@curl -fsS '$(TELEGYM_URL)/debug/messages/$(TELEGYM_TOKEN)?chat_id=$(TELEGYM_CHAT_ID)' | jq .messages

telegym-clear:
	@curl -fsS -X POST '$(TELEGYM_URL)/debug/messages/$(TELEGYM_TOKEN)/clear' | jq .
	@curl -fsS -X DELETE '$(TELEGYM_URL)/debug/files' | jq .
