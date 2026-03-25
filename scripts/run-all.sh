#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/bench-utils.sh"

log_info "========================================"
log_info "  Runtime Benchmark Suite — Full Run"
log_info "========================================"
log_info ""

# Save system info
system_info_json > "${RESULTS_DIR}/system-info.json"
runtime_versions_json > "${RESULTS_DIR}/runtime-versions.json"
log_ok "System info saved"

# Start PostgreSQL
log_info "Starting PostgreSQL..."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" up -d
sleep 3

# Initialize schema
PGPASSWORD=bench psql -h localhost -U bench -d bench \
    -f "${PROJECT_ROOT}/benchmarks/02-db-crud/schema.sql" > /dev/null 2>&1
log_ok "PostgreSQL ready"

WRK_RATE="${WRK_RATE:-5000}"  # safe default for WSL2; set WRK_RATE=50000 on bare metal

log_info ""
log_info "=== 1/5: HTTP Hello World ==="
"${PROJECT_ROOT}/benchmarks/01-http-hello-world/run.sh" "${WRK_RATE}"

log_info ""
log_info "=== 2/5: DB CRUD ==="
"${PROJECT_ROOT}/benchmarks/02-db-crud/run.sh"

log_info ""
log_info "=== 3/5: Next.js Serving ==="
"${PROJECT_ROOT}/benchmarks/03-nextjs-serving/run.sh" "${WRK_RATE}"

log_info ""
log_info "=== 4/5: Micro-benchmarks ==="
"${PROJECT_ROOT}/benchmarks/04-micro-benchmarks/run.sh"

log_info ""
log_info "=== 5/5: Polyglot vs Native ==="
"${PROJECT_ROOT}/benchmarks/05-polyglot-vs-native/run.sh" "${WRK_RATE}"

log_info ""
log_info "========================================"
log_ok "All benchmarks complete!"
log_info "Results in: ${RESULTS_DIR}/"
log_info "========================================"
