ARG ELIXIR_VERSION=1.19.3
ARG OTP_VERSION=28.1.1
ARG DEBIAN_VERSION=bookworm-20260610-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS builder

RUN apt-get update \
  && apt-get install --yes --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY assets assets
COPY lib lib
COPY priv priv
COPY config/runtime.exs config/
COPY rel rel

RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM debian:${DEBIAN_VERSION} AS runner

RUN apt-get update \
  && apt-get install --yes --no-install-recommends ca-certificates libstdc++6 libncurses6 openssl \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --home-dir /app --shell /usr/sbin/nologin eventsales

WORKDIR /app

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true

COPY --from=builder --chown=eventsales:eventsales /app/_build/prod/rel/event_sales ./

USER eventsales

CMD ["bin/event_sales", "start"]
