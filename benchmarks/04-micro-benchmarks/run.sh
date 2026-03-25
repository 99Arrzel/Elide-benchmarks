#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/bench-utils.sh"

RUNS=3
BENCHMARKS=("json" "crypto")
RUNTIMES=("node" "bun" "deno" "elide")

log_info "=== Micro-benchmarks ==="

for bench_type in "${BENCHMARKS[@]}"; do
    log_info "=== ${bench_type} ==="

    for runtime in "${RUNTIMES[@]}"; do
        log_info "--- ${runtime} / ${bench_type} ---"

        for run in $(seq 1 ${RUNS}); do
            log_info "Run ${run}/${RUNS}"

            case "${runtime}" in
                node)
                    OUTPUT=$(npx tsx "${SCRIPT_DIR}/${bench_type}/bench.ts" 2>&1)
                    ;;
                bun)
                    OUTPUT=$(bun "${SCRIPT_DIR}/${bench_type}/bench.ts" 2>&1)
                    ;;
                deno)
                    OUTPUT=$(deno run "${SCRIPT_DIR}/${bench_type}/bench.ts" 2>&1)
                    ;;
                elide)
                    OUTPUT=$(elide "${SCRIPT_DIR}/${bench_type}/bench.ts" 2>&1)
                    ;;
            esac

            echo "${OUTPUT}"
            save_result "micro-${bench_type}" "${runtime}-run${run}" "$(echo "${OUTPUT}" | tail -1)"
        done
    done
done

log_ok "Micro-benchmarks complete"
