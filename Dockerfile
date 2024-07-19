#### Builder
FROM hexpm/elixir:1.17.2-erlang-27.0-alpine-3.20.1 as buildcontainer

RUN mkdir /app
WORKDIR /app

# install build dependencies
RUN apk add --no-cache git gnupg make gcc g++ libc-dev

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
FROM alpine:3.20.1

ENV SHELL=sh

RUN adduser -S -H -u 999 -G nogroup lolek

RUN apk upgrade --no-cache
RUN apk add --no-cache openssl ncurses libstdc++ libgcc ca-certificates

COPY --from=buildcontainer --chmod=a+rX /app/_build/prod/rel/lolek /app

USER 999
WORKDIR /app

ENTRYPOINT ["./bin/lolek"]
CMD ["start"]
