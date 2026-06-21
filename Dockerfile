#### Builder
FROM hexpm/elixir:1.20.0-erlang-29.0.1-debian-trixie-20260518-slim AS buildcontainer

RUN mkdir /ytdlp
WORKDIR /ytdlp

# install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
  wget git gnupg make gcc g++ libc-dev \
  && rm -rf /var/lib/apt/lists/*

# yt-dlp source (https://github.com/yt-dlp/yt-dlp)
ARG YT_DLP_VERSION=2026.06.09
ARG YT_DLP_SHA256=e5d57466682cfa9d61e9cf7c8a4f09b00f4a62af37d3bbdc4bcffdf63615feac
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
FROM debian:trixie-20260518-slim

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

COPY --from=buildcontainer /ytdlp/yt-dlp /usr/local/bin
RUN chmod 755 /usr/local/bin/yt-dlp

ARG GALLERY_DL_VERSION=1.32.3
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
