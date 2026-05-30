#### Builder
FROM hexpm/elixir:1.19.5-erlang-28.3-debian-trixie-20260202-slim AS buildcontainer

RUN mkdir /ytdlp
WORKDIR /ytdlp

# install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
  wget git gnupg make gcc g++ libc-dev \
  && rm -rf /var/lib/apt/lists/*

# yt-dlp source (https://github.com/yt-dlp/yt-dlp)
ARG YT_DLP_VERSION=2026.03.17
ARG YT_DLP_SHA256=3bda0968a01cde70d26720653003b28553c71be14dcb2e5f4c24e9921fdad745
RUN wget -O yt-dlp https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/yt-dlp \
&& echo "${YT_DLP_SHA256}  yt-dlp" | sha256sum -c

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
# Using Debian for better V4L2 hardware encoder support on Raspberry Pi
FROM debian:trixie-20260202-slim

ENV SHELL=/bin/bash

# Install ffmpeg with V4L2 M2M support (hardware encoding for RPi)
# Debian's ffmpeg package includes v4l2_m2m encoder support
RUN apt-get update && apt-get install -y --no-install-recommends \
  ffmpeg \
  python3 \
  curl \
  ca-certificates \
  openssl \
  libncurses6 \
  libstdc++6 \
  && rm -rf /var/lib/apt/lists/*

COPY --from=buildcontainer /ytdlp/yt-dlp /usr/local/bin
RUN chmod 755 /usr/local/bin/yt-dlp

RUN useradd -r -u 999 -s /usr/sbin/nologin lolek

COPY --from=buildcontainer --chmod=755 /app/_build/prod/rel/lolek /app

# create downloads directory
RUN mkdir /downloads && chown -R lolek:nogroup /downloads

USER 999
WORKDIR /app

ENTRYPOINT ["./bin/lolek"]
CMD ["start"]
