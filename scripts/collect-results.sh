#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/bench-utils.sh"

log_info "Collecting results from ${RESULTS_DIR}/"

SUMMARY_FILE="${RESULTS_DIR}/summary-$(date +%Y%m%d-%H%M%S).json"

# Parse wrk2 output file and extract structured metrics
parse_wrk2() {
    local file="$1"
    local req_sec avg_latency p50 p75 p90 p99 p999
    req_sec=$(grep "Req/Sec" "$file" | awk '{print $2}' || echo "N/A")
    avg_latency=$(grep "Latency" "$file" | head -1 | awk '{print $2}' || echo "N/A")
    p50=$(grep "50.000%" "$file" | awk '{print $2}' || echo "N/A")
    p75=$(grep "75.000%" "$file" | awk '{print $2}' || echo "N/A")
    p90=$(grep "90.000%" "$file" | awk '{print $2}' || echo "N/A")
    p95=$(grep "95.000%" "$file" | awk '{print $2}' || echo "N/A")
    p99=$(grep "99.000%" "$file" | awk '{print $2}' || echo "N/A")
    p999=$(grep "99.900%" "$file" | awk '{print $2}' || echo "N/A")
    local total_req
    total_req=$(grep "requests in" "$file" | awk '{print $1}' || echo "N/A")
    local errors
    errors=$(grep "Socket errors\|Non-2xx" "$file" | head -1 || echo "none")

    cat <<METRICS
    {
      "req_per_sec": "${req_sec}",
      "avg_latency": "${avg_latency}",
      "p50": "${p50}",
      "p75": "${p75}",
      "p90": "${p90}",
      "p95": "${p95}",
      "p99": "${p99}",
      "p999": "${p999}",
      "total_requests": "${total_req}",
      "errors": "${errors}"
    }
METRICS
}

# Build JSON summary
echo "{" > "${SUMMARY_FILE}"
echo '  "generated_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",' >> "${SUMMARY_FILE}"

# System info
if [ -f "${RESULTS_DIR}/system-info.json" ]; then
    echo '  "system": '$(cat "${RESULTS_DIR}/system-info.json")',' >> "${SUMMARY_FILE}"
fi

# Runtime versions
if [ -f "${RESULTS_DIR}/runtime-versions.json" ]; then
    echo '  "runtimes": '$(cat "${RESULTS_DIR}/runtime-versions.json")',' >> "${SUMMARY_FILE}"
fi

# Parse wrk2 .txt results into structured data
echo '  "http_benchmarks": [' >> "${SUMMARY_FILE}"
first=true
for f in "${RESULTS_DIR}"/http-*.txt "${RESULTS_DIR}"/nextjs-*.txt "${RESULTS_DIR}"/polyglot-http-*.txt; do
    [ -f "$f" ] || continue
    if [ "$first" = true ]; then first=false; else echo ',' >> "${SUMMARY_FILE}"; fi
    echo '    { "file": "'$(basename "$f")'", "metrics": '$(parse_wrk2 "$f")' }' >> "${SUMMARY_FILE}"
done
echo '  ],' >> "${SUMMARY_FILE}"

# List all other result files
echo '  "other_results": [' >> "${SUMMARY_FILE}"
first=true
for f in "${RESULTS_DIR}"/*.json; do
    [ -f "$f" ] || continue
    [[ "$f" == *"summary"* ]] && continue
    [[ "$f" == *"system-info"* ]] && continue
    [[ "$f" == *"runtime-versions"* ]] && continue
    if [ "$first" = true ]; then first=false; else echo ',' >> "${SUMMARY_FILE}"; fi
    echo "    \"$(basename "$f")\"" >> "${SUMMARY_FILE}"
done
echo '  ]' >> "${SUMMARY_FILE}"
echo "}" >> "${SUMMARY_FILE}"

log_ok "Summary written to ${SUMMARY_FILE}"
log_info "Total result files: $(ls -1 "${RESULTS_DIR}"/*.txt "${RESULTS_DIR}"/*.json 2>/dev/null | wc -l)"
