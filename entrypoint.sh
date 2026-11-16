#!/bin/bash
# entrypoint.sh — zapret2 (nfqws2) DPI bypass + yt-dlp downloader

set -euo pipefail

QNUM="${NFQUEUE_NUM:-200}"
OUTPUT_DIR="${OUTPUT_DIR:-/downloads}"
PID_FILE="/var/run/nfqws2.pid"

cleanup() {
    trap - EXIT INT TERM
    echo "[zapret2] Shutting down..."
    if [[ -f "$PID_FILE" ]]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    iptables -t mangle -D OUTPUT -p tcp -m multiport --dports 80,443 -m mark ! --mark 0x40000000/0x40000000 -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:12 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p udp --dport 443 -m mark ! --mark 0x40000000/0x40000000 -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
    echo "[zapret2] Stopped."
}
trap cleanup EXIT INT TERM

# ─── Проверка прав iptables и запуск nfqws2 ──────────────────────────────────
NFQUEUE_ACTIVE=0
if iptables -t mangle -L OUTPUT >/dev/null 2>&1; then
    echo "[zapret2] Setting up iptables NFQUEUE rules (queue $QNUM)..."
    iptables -t mangle -A OUTPUT -p tcp -m multiport --dports 80,443 -m mark ! --mark 0x40000000/0x40000000 -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:12 -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    iptables -t mangle -A OUTPUT -p udp --dport 443 -m mark ! --mark 0x40000000/0x40000000 -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true

    # ── Benchmark / probe CLI mode ────────────────────────────────────────────
    if [[ "${1:-}" == "probe" || "${1:-}" == "--probe" ]]; then
        exec /app/probe.sh --benchmark
    fi

    # ── Strategy selection ────────────────────────────────────────────────────
    NFQWS2_OPT="${NFQWS2_OPT:-auto}"
    AUTO_STRATEGY="${AUTO_STRATEGY:-0}"

    if [[ "$NFQWS2_OPT" == "auto" || "$AUTO_STRATEGY" == "1" || -z "$NFQWS2_OPT" ]]; then
        echo "[zapret2] Auto-selecting DPI bypass strategy..."
        if [[ -f /app/probe.sh ]]; then
            /app/probe.sh --auto || true
        else
            echo "[zapret2] WARNING: /app/probe.sh not found, falling back to default." >&2
        fi
    else
        echo "[zapret2] Starting nfqws2 with custom options: ${NFQWS2_OPT}..."
        # shellcheck disable=SC2086
        nfqws2 \
            --qnum="$QNUM" \
            --daemon \
            --user=root \
            --pidfile="$PID_FILE" \
            --lua-init=@/opt/zapret2/lua/zapret-lib.lua \
            --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua \
            --blob=tls_google:@/opt/zapret2/fake/tls_clienthello_www_google_com.bin \
            --filter-tcp=443 --filter-l7=tls \
            --payload=tls_client_hello \
            ${NFQWS2_OPT}
    fi

    sleep 0.3
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        NFQUEUE_ACTIVE=1
        echo "[zapret2] nfqws2 running (pid $(cat "$PID_FILE")). DPI bypass active!"
    else
        echo "[zapret2] WARNING: nfqws2 failed to start." >&2
    fi
else
    echo "[zapret2] WARNING: iptables not available. Make sure to run container with --cap-add=NET_ADMIN (or --privileged)." >&2
    if [[ "${1:-}" == "probe" || "${1:-}" == "--probe" ]]; then
        echo "[zapret2] Cannot run probe without NET_ADMIN capability." >&2
        exit 1
    fi
fi

# ─── Mode selection ───────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    # ── Daemon mode: HTTP REST API / Web UI ───────────────────────────────────
    echo "[zapret2] Daemon mode. HTTP server starting on port ${SERVER_PORT:-8080}..."
    exec python3 /app/server.py
else
    # ── CLI Download mode ─────────────────────────────────────────────────────
    mkdir -p "$OUTPUT_DIR"
    echo "[yt-dlp] Downloading: $*"
    echo "[yt-dlp] Output dir:  $OUTPUT_DIR"
    echo "[yt-dlp] DPI bypass:  $( [[ $NFQUEUE_ACTIVE -eq 1 ]] && echo 'ACTIVE (zapret2 / nfqws2)' || echo 'INACTIVE (no NET_ADMIN)' )"

    COOKIES_FILE="${COOKIES_FILE:-/cookies.txt}"
    COOKIES_ARG=""
    if [[ -f "$COOKIES_FILE" ]]; then
        COOKIES_ARG="--cookies $COOKIES_FILE"
        echo "[yt-dlp] Using cookies: $COOKIES_FILE"
    fi

    # shellcheck disable=SC2086
    yt-dlp \
        --output "$OUTPUT_DIR/%(title)s.%(ext)s" \
        --merge-output-format mp4 \
        --no-playlist \
        ${COOKIES_ARG} \
        ${YT_DLP_OPTS:-} \
        "$@"

    echo "[yt-dlp] Done. Files saved to $OUTPUT_DIR"
fi
