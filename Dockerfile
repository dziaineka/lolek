# yt-dlp nightly version (https://github.com/yt-dlp/yt-dlp-nightly-builds/releases), installed
# as a PyPI dev-release in the final stage
ARG YT_DLP_VERSION=2026.08.20.234504

#### Builder
FROM hexpm/elixir:1.20.2-erlang-29.0.2-debian-trixie-20260623-slim AS buildcontainer

# install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
  git gnupg make gcc g++ libc-dev \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir /app
WORKDIR /app

COPY mix.exs ./
COPY mix.lock ./
COPY config ./config
RUN export MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(($(nproc) / 2)) && \
  export HEX_HTTP_TIMEOUT=120 && \
  mix local.hex --force && \
  mix local.rebar --force && \
  mix deps.get --only prod

COPY lib ./lib

RUN MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(($(nproc) / 2)) HEX_HTTP_TIMEOUT=120 MIX_ENV=prod mix release

# Main Docker Image
FROM debian:trixie-20260623-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/bash
ENV ELIXIR_ERL_OPTIONS="+fnu"

RUN apt-get update && apt-get install -y --no-install-recommends \
  ffmpeg \
  python3 \
  python3-pip \
  curl \
  ca-certificates \
  openssl \
  libsctp1 \
  libncurses6 \
  libstdc++6 \
  && rm -rf /var/lib/apt/lists/*

# yt-dlp: provides both the CLI and the yt_dlp Python module required by gallery-dl's
# ytdl extractor (extractor.ytdl.module=yt_dlp). Installed from its PyPI dev-release to
# pin the nightly build, e.g. 2026.08.20.234504 -> 2026.8.20.234504.dev0
ARG YT_DLP_VERSION
RUN YT_DLP_PYPI_VERSION=$(IFS=.; set -- ${YT_DLP_VERSION}; echo "$1.${2#0}.${3#0}.$4.dev0") && \
  pip3 install --pre "yt-dlp[default]==${YT_DLP_PYPI_VERSION}" --no-cache-dir --break-system-packages \
  && yt-dlp --version

ARG GALLERY_DL_VERSION=1.32.9
RUN pip3 install gallery-dl==${GALLERY_DL_VERSION} --no-cache-dir --break-system-packages \
  && gallery-dl --version

RUN useradd -r -u 999 -s /usr/sbin/nologin lolek

COPY --from=buildcontainer --chmod=755 /app/_build/prod/rel/lolek /app

# create downloads directory
RUN mkdir /downloads && chown -R lolek:nogroup /downloads

USER 999
WORKDIR /app

ENTRYPOINT ["./bin/lolek"]
CMD ["start"]
