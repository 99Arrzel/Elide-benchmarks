#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/bench-utils.sh"

PORT=3000
WRK_THREADS=4
WRK_CONNECTIONS=100
WRK_DURATION="30s"
WRK_WARMUP="10s"
WRK_RATE="${1:-10000}"
APP_DIR="${SCRIPT_DIR}/app"
RUNS=3

log_info "=== Next.js Serving Benchmark ==="

# Ensure app is built
if [ ! -d "${APP_DIR}/.next" ]; then
    log_info "Building Next.js app..."
    (cd "${APP_DIR}" && npm run build)
fi

serve_and_bench() {
    local runtime="$1"
    local start_cmd="$2"

    log_info "--- ${runtime} ---"

    for run in $(seq 1 ${RUNS}); do
        log_info "Run ${run}/${RUNS}"
        kill_on_port ${PORT}

        # Start server
        (cd "${APP_DIR}" && eval "${start_cmd}") &
        SERVER_PID=$!

        wait_for_server ${PORT} 30

        IDLE_RSS=$(get_rss ${SERVER_PID})

        # Warmup
        log_info "Warming up..."
        wrk2 -t${WRK_THREADS} -c${WRK_CONNECTIONS} -d${WRK_WARMUP} -R${WRK_RATE} \
            "http://localhost:${PORT}/" > /dev/null 2>&1 || true

        # Benchmark
        log_info "Benchmarking..."
        WRK_OUTPUT=$(run_wrk2 ${PORT} ${WRK_RATE} ${WRK_DURATION} ${WRK_THREADS} ${WRK_CONNECTIONS})

        LOAD_RSS=$(get_rss ${SERVER_PID})

        RAW_FILE="${RESULTS_DIR}/nextjs-${runtime}-run${run}-$(date +%Y%m%d-%H%M%S).txt"
        echo "${WRK_OUTPUT}" > "${RAW_FILE}"

        log_info "Memory (KB) — idle: ${IDLE_RSS}, load: ${LOAD_RSS}"
        echo "${WRK_OUTPUT}" | tail -20

        kill ${SERVER_PID} 2>/dev/null || true
        wait ${SERVER_PID} 2>/dev/null || true
        sleep 2
    done
}

# Node.js (baseline)
serve_and_bench "node" "PORT=${PORT} npx next start -p ${PORT}"

# Bun
serve_and_bench "bun" "PORT=${PORT} bun --bun node_modules/.bin/next start -p ${PORT}"

# Deno — may or may not work; document the result
if deno --version > /dev/null 2>&1; then
    serve_and_bench "deno" "PORT=${PORT} deno run -A node_modules/.bin/next start -p ${PORT}" || \
        log_warn "Deno failed to serve Next.js — this is a valid finding"
fi

# Elide — may or may not work; document the result
if elide --version > /dev/null 2>&1; then
    serve_and_bench "elide" "PORT=${PORT} elide node_modules/.bin/next start -p ${PORT}" || \
        log_warn "Elide failed to serve Next.js — this is a valid finding"
fi

log_ok "Next.js serving benchmark complete"
