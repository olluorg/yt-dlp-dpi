#!/bin/bash
# probe.sh — zapret2 (nfqws2) DPI bypass strategy auto-selection and benchmark

set -euo pipefail

QNUM="${NFQUEUE_NUM:-200}"
PID_FILE="/var/run/nfqws2.pid"
OUTPUT_DIR="${OUTPUT_DIR:-/downloads}"
CACHE_FILE="${OUTPUT_DIR}/.zapret_strategy"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}"
FORCE_PROBE="${FORCE_PROBE:-0}"

# Built-in pool of battle-tested zapret2 strategies for YouTube in Russia
STRATEGIES=(
    "--lua-desync=multidisorder:pos=1,midsld"
    "--lua-desync=fake:blob=tls_google --lua-desync=multidisorder:pos=1,midsld"
    "--lua-desync=fake:blob=tls_google --lua-desync=multisplit:pos=1,midsld"
    "--lua-desync=multisplit:pos=1,midsld"
    "--lua-desync=split2:pos=1,midsld"
    "--lua-desync=fake:blob=tls_google --lua-desync=split2:pos=1,midsld"
    "--lua-desync=multidisorder:pos=midsld"
    "--lua-desync=multisplit:pos=midsld"
    "--lua-desync=fake:blob=tls_google"
)

# Allow custom user strategies to be prepended via environment variable
if [[ -n "${EXTRA_STRATEGIES:-}" ]]; then
    IFS=';' read -ra EXTRA <<< "$EXTRA_STRATEGIES"
    STRATEGIES=("${EXTRA[@]}" "${STRATEGIES[@]}")
fi

stop_nfqws2() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            for _ in {1..10}; do
                if kill -0 "$pid" 2>/dev/null; then
                    sleep 0.05
                else
                    break
                fi
            done
        fi
        rm -f "$PID_FILE"
    fi
}

start_nfqws2() {
    local opt="$1"
    stop_nfqws2

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
        ${opt} >/dev/null 2>&1 || return 1

    sleep 0.2
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Checks connectivity and returns HTTP_CODE:TOTAL_TIME
check_target() {
    local url="$1"
    local timeout="$2"
    local max_t=$((timeout + 1))
    curl -s -o /dev/null -w "%{http_code}:%{time_total}" \
        --connect-timeout "$timeout" \
        --max-time "$max_t" \
        "$url" 2>/dev/null || echo "000:0"
}

# Test a given strategy against YouTube CDN targets
test_strategy() {
    local opt="$1"
    if ! start_nfqws2 "$opt"; then
        return 2  # Daemon start error
    fi

    # 1. Primary check: googlevideo CDN
    local res code time
    res="$(check_target "https://googlevideo.com" "$PROBE_TIMEOUT")"
    code="${res%%:*}"
    time="${res##*:}"

    if [[ "$code" != "000" && -n "$code" ]]; then
        echo "$time"
        return 0
    fi

    # 2. Secondary check: YouTube generate_204
    res="$(check_target "https://www.youtube.com/generate_204" "$PROBE_TIMEOUT")"
    code="${res%%:*}"
    time="${res##*:}"

    if [[ "$code" != "000" && -n "$code" ]]; then
        echo "$time"
        return 0
    fi

    return 1  # Connection blocked / timeout
}

save_strategy() {
    local strat="$1"
    mkdir -p "$(dirname "$CACHE_FILE")"
    echo "$strat" > "$CACHE_FILE" 2>/dev/null || true
}

run_auto() {
    # Check cached strategy first if not forced
    if [[ "$FORCE_PROBE" != "1" && -f "$CACHE_FILE" ]]; then
        local cached
        cached="$(cat "$CACHE_FILE" 2>/dev/null || true)"
        if [[ -n "$cached" ]]; then
            echo "[probe] Testing cached strategy from $CACHE_FILE..."
            local elapsed
            if elapsed="$(test_strategy "$cached")"; then
                echo "[probe] Cached strategy OK (${elapsed}s): $cached"
                return 0
            else
                echo "[probe] Cached strategy failed. Re-probing strategy pool..."
            fi
        fi
    fi

    echo "[probe] Searching for a working strategy among ${#STRATEGIES[@]} candidates..."
    local idx=1
    for strat in "${STRATEGIES[@]}"; do
        printf "[probe] [%d/%d] Testing: %s ... " "$idx" "${#STRATEGIES[@]}" "$strat"
        local elapsed ret=0
        elapsed="$(test_strategy "$strat")" || ret=$?

        if [[ $ret -eq 0 ]]; then
            printf "SUCCESS (%ss)\n" "$elapsed"
            echo "[probe] Selected strategy: $strat"
            save_strategy "$strat"
            return 0
        elif [[ $ret -eq 2 ]]; then
            printf "ERROR (nfqws2 failed to start)\n"
        else
            printf "TIMEOUT / BLOCKED\n"
        fi
        ((idx++))
    done

    echo "[probe] WARNING: All strategies failed! Reverting to default strategy." >&2
    start_nfqws2 "${STRATEGIES[0]}" || true
    return 1
}

run_benchmark() {
    echo "================================================================================"
    echo " zapret2 Strategy Benchmark"
    echo "================================================================================"
    printf "%-3s | %-8s | %-8s | %s\n" "#" "Latency" "Status" "Strategy"
    echo "----+----------+----------+-----------------------------------------------------"

    local idx=1
    local best_strat=""
    local best_time=999

    for strat in "${STRATEGIES[@]}"; do
        local elapsed ret=0
        elapsed="$(test_strategy "$strat")" || ret=$?

        if [[ $ret -eq 0 ]]; then
            printf "%-3d | %6ss  | [  OK  ] | %s\n" "$idx" "$elapsed" "$strat"
            # Compare float times
            if awk "BEGIN {exit !($elapsed < $best_time)}"; then
                best_time="$elapsed"
                best_strat="$strat"
            fi
        elif [[ $ret -eq 2 ]]; then
            printf "%-3d |    -     | [ ERR  ] | %s\n" "$idx" "$strat"
        else
            printf "%-3d |    -     | [ FAIL ] | %s\n" "$idx" "$strat"
        fi
        ((idx++))
    done

    echo "================================================================================"
    if [[ -n "$best_strat" ]]; then
        echo "[probe] Best performing strategy (${best_time}s):"
        echo "$best_strat"
        save_strategy "$best_strat"
        start_nfqws2 "$best_strat" || true
    else
        echo "[probe] No working strategy found."
    fi
}

case "${1:-auto}" in
    --benchmark|-b|benchmark|probe|--probe)
        run_benchmark
        ;;
    --auto|-a|auto)
        run_auto
        ;;
    --test|-t)
        shift
        test_strategy "$*"
        ;;
    --current|-c)
        if [[ -f "$CACHE_FILE" ]]; then
            cat "$CACHE_FILE"
        else
            echo "${STRATEGIES[0]}"
        fi
        ;;
    *)
        echo "Usage: $0 [--auto | --benchmark | --test \"<strategy>\" | --current]"
        exit 1
        ;;
esac
