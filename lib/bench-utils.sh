#!/usr/bin/env bash
set -euo pipefail

# Shared benchmark utilities

RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../results" && pwd)"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Wait for a server to be ready on a given port
wait_for_server() {
    local port="${1}"
    local timeout="${2:-10}"
    local elapsed=0
    while ! curl -sf "http://localhost:${port}/" > /dev/null 2>&1; do
        sleep 0.2
        elapsed=$(echo "$elapsed + 0.2" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_error "Server on port ${port} not ready after ${timeout}s"
            return 1
        fi
    done
    log_ok "Server ready on port ${port}"
}

# Run wrk2 and capture output
# Usage: run_wrk2 <port> <rate> <duration> <threads> <connections>
run_wrk2() {
    local port="${1}"
    local rate="${2:-10000}"
    local duration="${3:-30s}"
    local threads="${4:-4}"
    local connections="${5:-100}"

    # --u_latency extends the HDR histogram max trackable value to avoid
    # "counts_index: Assertion failed" crashes when latencies spike
    # (common on WSL2 or when rate exceeds server capacity)
    wrk2 -t"${threads}" -c"${connections}" -d"${duration}" -R"${rate}" \
        --u_latency --latency "http://localhost:${port}/" 2>&1 || {
        log_warn "wrk2 crashed or failed — rate ${rate} may be too high for this server"
        echo "wrk2 FAILED at rate ${rate}"
    }
}

# Get RSS memory of a process in KB
get_rss() {
    local pid="${1}"
    ps -o rss= -p "${pid}" 2>/dev/null | tr -d ' '
}

# Collect system info as JSON
system_info_json() {
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
    local cpu_cores
    cpu_cores=$(nproc)
    local mem_total_kb
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local kernel
    kernel=$(uname -r)

    cat <<EOF
{
  "cpu": "${cpu_model}",
  "cores": ${cpu_cores},
  "memory_mb": $((mem_total_kb / 1024)),
  "kernel": "${kernel}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Get runtime versions as JSON
runtime_versions_json() {
    local node_v bun_v deno_v elide_v
    node_v=$(node --version 2>/dev/null || echo "not installed")
    bun_v=$(bun --version 2>/dev/null || echo "not installed")
    deno_v=$(deno --version 2>/dev/null | head -1 || echo "not installed")
    elide_v=$(elide --version 2>/dev/null || echo "not installed")

    cat <<EOF
{
  "node": "${node_v}",
  "bun": "${bun_v}",
  "deno": "${deno_v}",
  "elide": "${elide_v}"
}
EOF
}

# Kill process on a port
kill_on_port() {
    local port="${1}"
    local pid
    pid=$(lsof -ti :"${port}" 2>/dev/null || true)
    if [[ -n "${pid}" ]]; then
        kill "${pid}" 2>/dev/null || true
        sleep 0.5
    fi
}

# Save benchmark result as JSON
# Usage: save_result <benchmark_name> <runtime> <json_data>
save_result() {
    local bench_name="${1}"
    local runtime="${2}"
    local data="${3}"
    local outfile="${RESULTS_DIR}/${bench_name}-${runtime}-$(date +%Y%m%d-%H%M%S).json"

    echo "${data}" > "${outfile}"
    log_ok "Results saved to ${outfile}"
}
