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
