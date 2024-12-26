#### Builder
FROM hexpm/elixir:1.18.0-erlang-27.2-alpine-3.21.0 AS buildcontainer

RUN mkdir /ytdlp
WORKDIR /ytdlp

# Determine the architecture and set it as an environment variable
RUN ARCH=$(apk --print-arch) && \
  case $ARCH in \
    x86) ARCH=amd64;; \
    armhf) ARCH=armhf;; \
    aarch64) ARCH=arm64;; \
    *) echo "Unsupported architecture: $ARCH"; exit 1;; \
  esac && \
  echo "$ARCH" > /tmp/arch_env

# yt-dlp source (https://github.com/yt-dlp/yt-dlp)
ENV BUILD_VERSION=2024.12.23
RUN wget https://github.com/yt-dlp/yt-dlp/releases/download/${BUILD_VERSION}/SHA2-256SUMS \
&& SHA256_SUM=`grep 'yt-dlp$' SHA2-256SUMS` \
&& wget https://github.com/yt-dlp/yt-dlp/releases/download/${BUILD_VERSION}/yt-dlp \
&& echo "${SHA256_SUM}" | sha256sum -c

# ffmpeg static source (https://johnvansickle.com/ffmpeg/)
RUN ARCH=$(cat /tmp/arch_env) \
&& wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${ARCH}-static.tar.xz \
&& wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${ARCH}-static.tar.xz.md5 \
&& md5sum -c ffmpeg-release-${ARCH}-static.tar.xz.md5 \
&& tar Jxf ffmpeg-release-${ARCH}-static.tar.xz

# rename extracted ffmpeg directory
RUN mv ffmpeg-*-static ffmpeg-amd64-static

# install build dependencies
RUN apk add --no-cache git gnupg make gcc g++ libc-dev

RUN mkdir /app
WORKDIR /app

COPY mix.exs ./
COPY mix.lock ./
COPY config ./config
RUN mix local.hex --force && \
  mix local.rebar --force && \
  mix deps.get --only prod && \
  mix deps.compile

COPY lib ./lib

RUN MIX_ENV=prod mix release

# Main Docker Image
FROM alpine:3.21.0

ENV SHELL=/bin/sh

# bring in the yt-dlp and ffmpeg

COPY --from=buildcontainer /ytdlp/ffmpeg-amd64-static/ffmpeg /usr/local/bin
COPY --from=buildcontainer /ytdlp/ffmpeg-amd64-static/ffprobe /usr/local/bin
# COPY ./yt-dlp.conf /etc/yt-dlp.conf

COPY --from=buildcontainer /ytdlp/yt-dlp /usr/local/bin
RUN chmod 755 /usr/local/bin/yt-dlp

RUN adduser -S -H -u 999 -G nogroup lolek

RUN apk upgrade --no-cache
RUN apk add --no-cache openssl ncurses libstdc++ libgcc ca-certificates python3

COPY --from=buildcontainer --chmod=755 /app/_build/prod/rel/lolek /app

# create downloads directory
RUN mkdir /downloads && chown -R lolek:nogroup /downloads

USER 999
WORKDIR /app

ENTRYPOINT ["./bin/lolek"]
CMD ["start"]
