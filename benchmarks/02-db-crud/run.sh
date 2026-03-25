#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/bench-utils.sh"

RUNS=3

log_info "=== DB CRUD Benchmark ==="

# Ensure PG is running
if ! pg_isready -h localhost -U bench -d bench > /dev/null 2>&1; then
    log_info "Starting PostgreSQL..."
    docker compose -f "${PROJECT_ROOT}/docker-compose.yml" up -d
    sleep 3
fi

# Install deps
log_info "Installing dependencies..."
(cd "${SCRIPT_DIR}/node" && npm install --silent)
(cd "${SCRIPT_DIR}/bun" && bun install --silent)

run_bench() {
    local runtime="$1"
    local label="$2"
    local cmd="$3"

    log_info "--- ${label} ---"
    for run in $(seq 1 ${RUNS}); do
        log_info "Run ${run}/${RUNS}"

        # Reset table
        PGPASSWORD=bench psql -h localhost -U bench -d bench -f "${SCRIPT_DIR}/schema.sql" > /dev/null 2>&1

        # Run benchmark in background, capture output via temp file
        TMPOUT=$(mktemp)
        eval "${cmd}" > "${TMPOUT}" 2>&1 &
        BENCH_PID=$!

        # Sample RSS while benchmark runs (background sampler)
        PEAK_RSS_FILE=$(mktemp)
        echo "0" > "${PEAK_RSS_FILE}"
        (while kill -0 ${BENCH_PID} 2>/dev/null; do
            rss=$(get_rss ${BENCH_PID})
            prev=$(cat "${PEAK_RSS_FILE}")
            if [[ -n "${rss}" ]] && (( rss > prev )); then
                echo "${rss}" > "${PEAK_RSS_FILE}"
            fi
            sleep 0.5
        done) &
        SAMPLER_PID=$!

        wait ${BENCH_PID} || true
        wait ${SAMPLER_PID} 2>/dev/null || true
        OUTPUT=$(cat "${TMPOUT}")
        PEAK_RSS=$(cat "${PEAK_RSS_FILE}" 2>/dev/null || echo "N/A")
        rm -f "${TMPOUT}" "${PEAK_RSS_FILE}"

        echo "${OUTPUT}"
        log_info "Peak RSS (KB): ${PEAK_RSS}"

        # Save result
        RESULT_JSON=$(echo "${OUTPUT}" | grep -A999 '^{' | head -n -0 || echo "${OUTPUT}")
        save_result "db-crud" "${runtime}-run${run}" "${RESULT_JSON}"
    done
}

run_bench "node-pg" "Node.js (pg)" "npx tsx ${SCRIPT_DIR}/node/bench.ts"
run_bench "bun-pg" "Bun (pg)" "bun ${SCRIPT_DIR}/bun/bench-pg.ts"
run_bench "bun-native" "Bun (Bun.sql)" "bun ${SCRIPT_DIR}/bun/bench-native.ts"
run_bench "deno" "Deno (deno-postgres)" "deno run --allow-net --allow-env --allow-read ${SCRIPT_DIR}/deno/bench.ts"
run_bench "elide" "Elide (pg fallback)" "elide ${SCRIPT_DIR}/elide/bench.ts"

log_ok "DB CRUD benchmark complete"
