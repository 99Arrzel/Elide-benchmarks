#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/bench-utils.sh"

PORT=3000
WRK_THREADS=4
WRK_CONNECTIONS=100
WRK_DURATION="${WRK_DURATION:-30s}"
WRK_WARMUP="${WRK_WARMUP:-10s}"
WRK_RATE="${1:-5000}"   # pass target rate as arg, default 5k (safe for WSL2; increase on bare metal)
MODE="${2:-fixed}"       # "fixed" or "saturate" — saturate finds max throughput first

RUNTIMES=("node" "bun" "deno" "elide")
RUNS=3

start_server() {
    local runtime="$1"
    kill_on_port ${PORT}
    case "${runtime}" in
        node)
            npx tsx "${SCRIPT_DIR}/node/server.ts" &
            ;;
        bun)
            bun "${SCRIPT_DIR}/bun/server.ts" &
            ;;
        deno)
            deno run --allow-net --allow-env "${SCRIPT_DIR}/deno/server.ts" &
            ;;
        elide)
            elide "${SCRIPT_DIR}/elide/server.ts" &
            ;;
    esac
    SERVER_PID=$!
    wait_for_server ${PORT} 15
}

stop_server() {
    kill ${SERVER_PID} 2>/dev/null || true
    wait ${SERVER_PID} 2>/dev/null || true
    sleep 1
}

# Find saturation point: binary search for max sustainable throughput
find_saturation() {
    local runtime="$1"
    local low=1000
    local high=500000
    local best=1000

    log_info "Finding saturation point for ${runtime}..."
    start_server "${runtime}"

    # Quick warmup
    wrk2 -t${WRK_THREADS} -c${WRK_CONNECTIONS} -d5s -R1000 \
        "http://localhost:${PORT}/" > /dev/null 2>&1 || true

    while (( high - low > 5000 )); do
        local mid=$(( (low + high) / 2 ))
        log_info "  Testing rate ${mid}..."
        local output
        output=$(wrk2 -t${WRK_THREADS} -c${WRK_CONNECTIONS} -d10s -R${mid} \
            --latency "http://localhost:${PORT}/" 2>&1)

        # Check if errors or extreme latency (p99 > 100ms means saturated)
        local errors
        errors=$(echo "${output}" | grep -c "Socket errors\|Non-2xx" || true)
        local p99_raw p99_ms
        p99_raw=$(echo "${output}" | grep "99.000%" | awk '{print $2}' || echo "0ms")
        # Normalize to milliseconds — wrk2 reports s/ms/us
        if [[ "${p99_raw}" == *s ]] && [[ "${p99_raw}" != *ms ]]; then
            p99_ms=$(echo "${p99_raw}" | sed 's/s//' | awk '{printf "%.2f", $1 * 1000}')
        elif [[ "${p99_raw}" == *ms ]]; then
            p99_ms=$(echo "${p99_raw}" | sed 's/ms//')
        elif [[ "${p99_raw}" == *us ]]; then
            p99_ms=$(echo "${p99_raw}" | sed 's/us//' | awk '{printf "%.2f", $1 / 1000}')
        else
            p99_ms="${p99_raw}"
        fi

        if [[ ${errors} -gt 0 ]] || (( $(echo "${p99_ms} > 100" | bc -l 2>/dev/null || echo 0) )); then
            high=${mid}
        else
            best=${mid}
            low=${mid}
        fi
    done

    stop_server
    echo "${best}"
}

run_at_rate() {
    local runtime="$1"
    local rate="$2"
    local label="$3"

    log_info "--- ${runtime} @ ${rate} req/s (${label}) ---"

    for run in $(seq 1 ${RUNS}); do
        log_info "Run ${run}/${RUNS}"

        start_server "${runtime}"

        # Get idle memory
        IDLE_RSS=$(get_rss ${SERVER_PID})

        # Warmup
        log_info "Warming up for ${WRK_WARMUP}..."
        wrk2 -t${WRK_THREADS} -c${WRK_CONNECTIONS} -d${WRK_WARMUP} -R${rate} \
            "http://localhost:${PORT}/" > /dev/null 2>&1 || true

        # Get memory after warmup
        WARM_RSS=$(get_rss ${SERVER_PID})

        # Benchmark
        log_info "Benchmarking for ${WRK_DURATION}..."
        WRK_OUTPUT=$(run_wrk2 ${PORT} ${rate} ${WRK_DURATION} ${WRK_THREADS} ${WRK_CONNECTIONS})

        # Get memory under load
        LOAD_RSS=$(get_rss ${SERVER_PID})

        # Save raw wrk2 output
        RAW_FILE="${RESULTS_DIR}/http-hello-${runtime}-${label}-run${run}-$(date +%Y%m%d-%H%M%S).txt"
        echo "${WRK_OUTPUT}" > "${RAW_FILE}"

        log_info "Memory (KB) — idle: ${IDLE_RSS}, warm: ${WARM_RSS}, load: ${LOAD_RSS}"
        echo "${WRK_OUTPUT}" | tail -20

        stop_server
    done
}

log_info "=== HTTP Hello World Benchmark ==="
log_info "Mode: ${MODE} | Duration: ${WRK_DURATION} | Threads: ${WRK_THREADS} | Connections: ${WRK_CONNECTIONS}"

if [[ "${MODE}" == "saturate" ]]; then
    # Phase 1: Find saturation point per runtime
    declare -A MAX_RATES
    for runtime in "${RUNTIMES[@]}"; do
        MAX_RATES[${runtime}]=$(find_saturation "${runtime}")
        log_ok "${runtime} saturation point: ${MAX_RATES[${runtime}]} req/s"
    done

    # Phase 2: Run at 50%, 75%, 90% of each runtime's max
    for runtime in "${RUNTIMES[@]}"; do
        max=${MAX_RATES[${runtime}]}
        for pct in 50 75 90; do
            rate=$(( max * pct / 100 ))
            run_at_rate "${runtime}" "${rate}" "${pct}pct"
        done
    done
else
    # Fixed rate mode — run all runtimes at the same rate
    for runtime in "${RUNTIMES[@]}"; do
        run_at_rate "${runtime}" "${WRK_RATE}" "fixed"
    done
fi

log_ok "HTTP Hello World benchmark complete"
