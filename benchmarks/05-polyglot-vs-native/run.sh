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
RUNS=3

# Ensure Kotlin uses system JDK, not Elide's broken java shim
if [ -d "/usr/lib/jvm/default-java" ]; then
    export JAVA_HOME="/usr/lib/jvm/default-java"
    export PATH="${JAVA_HOME}/bin:${PATH}"
fi

log_info "=== Polyglot vs Native Benchmark ==="

# Ensure PG is running
if ! pg_isready -h localhost -U bench -d bench > /dev/null 2>&1; then
    log_info "Starting PostgreSQL..."
    docker compose -f "${PROJECT_ROOT}/docker-compose.yml" up -d
    sleep 3
fi

# Use venv python if available, otherwise system python
VENV_PYTHON="${PROJECT_ROOT}/.venv/bin/python3"
if [ -x "${VENV_PYTHON}" ]; then
    PYTHON="${VENV_PYTHON}"
    log_info "Using venv Python: ${PYTHON}"
else
    PYTHON="python3"
    log_warn "No venv found — using system python3. Run scripts/setup.sh first for best results."
fi

# Install Python deps for CPython
if [ -f "${SCRIPT_DIR}/cpython/requirements.txt" ]; then
    log_info "Installing CPython dependencies..."
    "${PYTHON}" -m pip install -r "${SCRIPT_DIR}/cpython/requirements.txt" -q
fi

### === HTTP BENCHMARKS === ###

http_bench() {
    local label="$1"
    local start_cmd="$2"

    log_info "--- HTTP: ${label} ---"

    for run in $(seq 1 ${RUNS}); do
        log_info "Run ${run}/${RUNS}"
        kill_on_port ${PORT}

        eval "${start_cmd}" &
        SERVER_PID=$!

        wait_for_server ${PORT} 15

        # Warmup
        wrk2 -t${WRK_THREADS} -c${WRK_CONNECTIONS} -d${WRK_WARMUP} -R${WRK_RATE} \
            "http://localhost:${PORT}/" > /dev/null 2>&1 || true

        # Benchmark
        WRK_OUTPUT=$(run_wrk2 ${PORT} ${WRK_RATE} ${WRK_DURATION} ${WRK_THREADS} ${WRK_CONNECTIONS})
        LOAD_RSS=$(get_rss ${SERVER_PID})

        RAW_FILE="${RESULTS_DIR}/polyglot-http-${label// /-}-run${run}-$(date +%Y%m%d-%H%M%S).txt"
        echo "${WRK_OUTPUT}" > "${RAW_FILE}"

        log_info "Memory (KB): ${LOAD_RSS}"
        echo "${WRK_OUTPUT}" | tail -15

        kill ${SERVER_PID} 2>/dev/null || true
        wait ${SERVER_PID} 2>/dev/null || true
        sleep 1
    done
}

http_bench "cpython" "PORT=${PORT} ${PYTHON} ${SCRIPT_DIR}/cpython/http-server.py"
http_bench "elide-python" "PORT=${PORT} elide ${SCRIPT_DIR}/elide-python/http-server.py"
http_bench "kotlin-jvm" "PORT=${PORT} kotlin ${SCRIPT_DIR}/kotlin-jvm/http-server.kts"
http_bench "elide-kotlin" "PORT=${PORT} elide ${SCRIPT_DIR}/elide-kotlin/http-server.kts"

### === DB BENCHMARKS === ###

db_bench() {
    local label="$1"
    local cmd="$2"

    log_info "--- DB CRUD: ${label} ---"

    for run in $(seq 1 ${RUNS}); do
        log_info "Run ${run}/${RUNS}"

        # Reset table
        PGPASSWORD=bench psql -h localhost -U bench -d bench \
            -f "${SCRIPT_DIR}/../02-db-crud/schema.sql" > /dev/null 2>&1

        OUTPUT=$(eval "${cmd}" 2>&1)
        echo "${OUTPUT}"
        save_result "polyglot-db" "${label// /-}-run${run}" "$(echo "${OUTPUT}" | grep -A999 '^{' || echo "${OUTPUT}")"
    done
}

db_bench "cpython" "${PYTHON} ${SCRIPT_DIR}/cpython/db-crud.py"
db_bench "elide-python" "elide ${SCRIPT_DIR}/elide-python/db-crud.py"
db_bench "kotlin-jvm" "kotlin ${SCRIPT_DIR}/kotlin-jvm/db-crud.kts"
db_bench "elide-kotlin" "elide ${SCRIPT_DIR}/elide-kotlin/db-crud.kts"

log_ok "Polyglot vs Native benchmark complete"
