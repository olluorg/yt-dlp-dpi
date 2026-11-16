ARG DENO_VERSION=2.5.6

# ─── Stage 0: Deno runtime binary for JS challenge solving ────────────────────
FROM denoland/deno:bin-${DENO_VERSION} AS deno

# ─── Stage 1: fetch & prepare zapret2 ──────────────────────────────────────────
FROM debian:bookworm-slim AS builder

ARG ZAPRET2_VER=v1.0.7
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        tar \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/zapret2
RUN curl -sSL "https://github.com/bol-van/zapret2/releases/download/${ZAPRET2_VER}/zapret2-${ZAPRET2_VER}.tar.gz" -o zapret2.tar.gz \
    && tar -xzf zapret2.tar.gz --strip-components=1 \
    && mkdir -p /out/bin /out/lua /out/fake \
    && cp -r lua/* /out/lua/ \
    && cp -r files/fake/* /out/fake/ \
    && ARCH="${TARGETARCH:-}"; \
       if [ -z "$ARCH" ]; then \
           case "$(uname -m)" in \
               x86_64) ARCH="amd64" ;; \
               aarch64) ARCH="arm64" ;; \
               armv7l) ARCH="arm" ;; \
               *) ARCH="amd64" ;; \
           esac; \
       fi; \
       case "$ARCH" in \
           "amd64") ARCH_DIR="linux-x86_64" ;; \
           "arm64") ARCH_DIR="linux-arm64" ;; \
           "arm")   ARCH_DIR="linux-arm" ;; \
           *)       ARCH_DIR="linux-x86_64" ;; \
       esac \
    && cp binaries/${ARCH_DIR}/nfqws2 /out/bin/nfqws2 \
    && chmod +x /out/bin/nfqws2

# ─── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        procps \
        ffmpeg \
        curl \
        ca-certificates \
        python3 \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Используем legacy-backend: nf_tables может отсутствовать или конфликтовать в контейнерах
RUN update-alternatives --set iptables  /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Копируем deno для решения JS challenge в yt-dlp
COPY --from=deno /deno /usr/local/bin/deno

# Копируем zapret2 компоненты
COPY --from=builder /out/bin/nfqws2 /usr/local/bin/nfqws2
COPY --from=builder /out/lua/      /opt/zapret2/lua/
COPY --from=builder /out/fake/     /opt/zapret2/fake/

# Устанавливаем yt-dlp с рекомендованными зависимостями
RUN pip3 install --no-cache-dir --break-system-packages "yt-dlp[default]"

WORKDIR /downloads
VOLUME ["/downloads"]

COPY entrypoint.sh /entrypoint.sh
COPY probe.sh      /app/probe.sh
COPY server.py     /app/server.py
RUN chmod +x /entrypoint.sh /app/probe.sh /usr/local/bin/nfqws2 /usr/local/bin/deno

ENV NFQUEUE_NUM=200 \
    SERVER_PORT=8080 \
    OUTPUT_DIR=/downloads \
    DENO_NO_UPDATE_CHECK=1 \
    AUTO_STRATEGY=1 \
    NFQWS2_OPT="auto"

ENTRYPOINT ["/entrypoint.sh"]
