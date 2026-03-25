# Runtime Benchmarks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained benchmark suite comparing Elide, Node.js, Bun, and Deno across HTTP, database, micro-benchmarks, Next.js serving, and polyglot execution.

**Architecture:** Each benchmark lives in its own directory with per-runtime implementations and a `run.sh` orchestrator. A top-level `run-all.sh` chains them. PostgreSQL runs in Docker; runtimes run bare metal. Results are written to `results/` as JSON.

**Tech Stack:** TypeScript (all 4 runtimes), Python (CPython + Elide), Kotlin (JVM + Elide), PostgreSQL 16, Docker Compose, wrk2, bash scripts.

---

## File Map

```
elide-comparisons/
├── .gitignore
├── docker-compose.yml
├── postgres/
│   └── postgresql.conf
├── lib/
│   └── bench-utils.sh                    # shared bash helpers (timing, wrk2 wrapper, results output)
├── benchmarks/
│   ├── 01-http-hello-world/
│   │   ├── node/server.ts
│   │   ├── bun/server.ts
│   │   ├── deno/server.ts
│   │   ├── elide/server.ts
│   │   └── run.sh
│   ├── 02-db-crud/
│   │   ├── schema.sql
│   │   ├── node/bench.ts
│   │   ├── node/package.json
│   │   ├── bun/bench-pg.ts
│   │   ├── bun/bench-native.ts
│   │   ├── bun/package.json
│   │   ├── deno/bench.ts
│   │   ├── deno/deno.json
│   │   ├── elide/bench.ts
│   │   └── run.sh
│   ├── 03-nextjs-serving/
│   │   ├── app/                          # scaffolded Next.js project
│   │   └── run.sh
│   ├── 04-micro-benchmarks/
│   │   ├── json/bench.ts                 # single file, runtime-agnostic
│   │   ├── crypto/bench.ts               # single file, runtime-agnostic
│   │   └── run.sh
│   └── 05-polyglot-vs-native/
│       ├── elide-python/http-server.py
│       ├── cpython/http-server.py
│       ├── elide-python/db-crud.py
│       ├── cpython/db-crud.py
│       ├── cpython/requirements.txt
│       ├── elide-kotlin/http-server.kts
│       ├── kotlin-jvm/http-server.kts
│       ├── elide-kotlin/db-crud.kts
│       ├── kotlin-jvm/db-crud.kts
│       └── run.sh
├── results/
│   └── .gitkeep
├── scripts/
│   ├── setup.sh
│   ├── run-all.sh
│   └── collect-results.sh
```

---

## Task 1: Project Scaffolding

**Files:**
- Create: `.gitignore`
- Create: `docker-compose.yml`
- Create: `postgres/postgresql.conf`
- Create: `lib/bench-utils.sh`
- Create: `results/.gitkeep`

- [ ] **Step 1: Initialize git repo**

```bash
cd /home/link/work/elide-comparisons
git init
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
# Dependencies
node_modules/
.bun/

# Next.js
.next/
out/

# Results (generated)
results/*.json
results/*.csv
results/*.txt
!results/.gitkeep

# OS
.DS_Store
Thumbs.db

# Runtime caches
.deno/
.elide/

# Python
__pycache__/
*.pyc
.venv/
venv/

# Kotlin
*.class
build/
```

- [ ] **Step 3: Create `docker-compose.yml`**

```yaml
services:
  postgres:
    image: postgres:16
    container_name: bench-postgres
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: bench
      POSTGRES_PASSWORD: bench
      POSTGRES_DB: bench
    volumes:
      - ./postgres/postgresql.conf:/etc/postgresql/postgresql.conf
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    shm_size: 512mb
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bench"]
      interval: 2s
      timeout: 5s
      retries: 10
```

- [ ] **Step 4: Create `postgres/postgresql.conf`**

```ini
# PostgreSQL 16 — benchmark configuration
# Intentionally moderate defaults. Goal: measure runtime driver perf, not PG tuning.

listen_addresses = '*'
port = 5432
max_connections = 100

# Memory
shared_buffers = 256MB
work_mem = 16MB
effective_cache_size = 768MB
maintenance_work_mem = 128MB

# WAL — relaxed for benchmarking (we don't care about crash recovery)
wal_level = minimal
max_wal_senders = 0
fsync = off
synchronous_commit = off
full_page_writes = off

# Logging — minimal
log_min_messages = warning
log_min_error_statement = error

# Planner
random_page_cost = 1.1
effective_io_concurrency = 200
```

- [ ] **Step 5: Create `lib/bench-utils.sh`**

```bash
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

    wrk2 -t"${threads}" -c"${connections}" -d"${duration}" -R"${rate}" \
        --latency "http://localhost:${port}/"
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
```

- [ ] **Step 6: Create `results/.gitkeep`**

Empty file.

- [ ] **Step 7: Commit**

```bash
git add .gitignore docker-compose.yml postgres/postgresql.conf lib/bench-utils.sh results/.gitkeep
git commit -m "chore: project scaffolding with docker-compose, pg config, and bench utilities"
```

---

## Task 2: HTTP Hello World Servers

**Files:**
- Create: `benchmarks/01-http-hello-world/node/server.ts`
- Create: `benchmarks/01-http-hello-world/bun/server.ts`
- Create: `benchmarks/01-http-hello-world/deno/server.ts`
- Create: `benchmarks/01-http-hello-world/elide/server.ts`

- [ ] **Step 1: Create Node.js HTTP server**

`benchmarks/01-http-hello-world/node/server.ts`
```typescript
import { createServer } from "node:http";

const PORT = parseInt(process.env.PORT || "3000");

const server = createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Hello, World!");
});

server.listen(PORT, () => {
  console.log(`Node.js listening on port ${PORT}`);
});
```

- [ ] **Step 2: Create Bun HTTP server**

`benchmarks/01-http-hello-world/bun/server.ts`
```typescript
const PORT = parseInt(process.env.PORT || "3000");

Bun.serve({
  port: PORT,
  fetch() {
    return new Response("Hello, World!", {
      headers: { "Content-Type": "text/plain" },
    });
  },
});

console.log(`Bun listening on port ${PORT}`);
```

- [ ] **Step 3: Create Deno HTTP server**

`benchmarks/01-http-hello-world/deno/server.ts`
```typescript
const PORT = parseInt(Deno.env.get("PORT") || "3000");

Deno.serve({ port: PORT }, () => {
  return new Response("Hello, World!", {
    headers: { "Content-Type": "text/plain" },
  });
});
```

- [ ] **Step 4: Create Elide HTTP server**

`benchmarks/01-http-hello-world/elide/server.ts`
```typescript
// Elide uses its own built-in HTTP API: Elide.http
const app = Elide.http;
const PORT = parseInt(process.env.PORT || "3000");

app.router.handle("GET", "/", (request, response, context) => {
  response.send(200, "Hello, World!");
});

app.config.port = PORT;
app.config.onBind(() => {
  console.log(`Elide listening on port ${PORT}`);
});
app.start();
```

- [ ] **Step 5: Verify each server starts manually**

```bash
# Test each one (Ctrl+C to stop after verifying):
cd benchmarks/01-http-hello-world
PORT=3000 npx tsx node/server.ts
PORT=3000 bun bun/server.ts
PORT=3000 deno run --allow-net --allow-env deno/server.ts
PORT=3000 elide elide/server.ts
```

- [ ] **Step 6: Commit**

```bash
git add benchmarks/01-http-hello-world/
git commit -m "feat: add HTTP hello world servers for node, bun, deno, elide"
```

---

## Task 3: HTTP Hello World Run Script

**Files:**
- Create: `benchmarks/01-http-hello-world/run.sh`

- [ ] **Step 1: Create `run.sh`**

`benchmarks/01-http-hello-world/run.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/bench-utils.sh"

PORT=3000
WRK_THREADS=4
WRK_CONNECTIONS=100
WRK_DURATION="${WRK_DURATION:-30s}"
WRK_WARMUP="${WRK_WARMUP:-10s}"
WRK_RATE="${1:-50000}"  # pass target rate as arg, default 50k
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
        local p99
        p99=$(echo "${output}" | grep "99.000%" | awk '{print $2}' | sed 's/[a-z]//g' || echo "0")

        if [[ ${errors} -gt 0 ]] || (( $(echo "${p99} > 100" | bc -l 2>/dev/null || echo 0) )); then
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x benchmarks/01-http-hello-world/run.sh
```

- [ ] **Step 3: Test with a quick dry run (low rate, short duration)**

```bash
# Override duration via env var, rate via positional arg
WRK_DURATION=5s WRK_WARMUP=2s benchmarks/01-http-hello-world/run.sh 100
```

- [ ] **Step 4: Commit**

```bash
git add benchmarks/01-http-hello-world/run.sh
git commit -m "feat: add run script for HTTP hello world benchmark"
```

---

## Task 4: DB CRUD Schema and Benchmarks

**Files:**
- Create: `benchmarks/02-db-crud/schema.sql`
- Create: `benchmarks/02-db-crud/node/package.json`
- Create: `benchmarks/02-db-crud/node/bench.ts`
- Create: `benchmarks/02-db-crud/bun/package.json`
- Create: `benchmarks/02-db-crud/bun/bench-pg.ts`
- Create: `benchmarks/02-db-crud/bun/bench-native.ts`
- Create: `benchmarks/02-db-crud/deno/deno.json`
- Create: `benchmarks/02-db-crud/deno/bench.ts`
- Create: `benchmarks/02-db-crud/elide/bench.ts`

- [ ] **Step 1: Create schema.sql**

`benchmarks/02-db-crud/schema.sql`
```sql
DROP TABLE IF EXISTS users;
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index on email for realistic SELECT/UPDATE/DELETE by email
CREATE INDEX idx_users_email ON users(email);
```

- [ ] **Step 2: Create Node.js DB benchmark**

`benchmarks/02-db-crud/node/package.json`
```json
{
  "name": "db-crud-node",
  "private": true,
  "type": "module",
  "dependencies": {
    "pg": "^8.13.0"
  },
  "devDependencies": {
    "tsx": "^4.19.0"
  }
}
```

`benchmarks/02-db-crud/node/bench.ts`
```typescript
import pg from "pg";
const { Client } = pg;

const WARMUP_OPS = 1000;
const MEASURE_OPS = 10000;

const client = new Client({
  host: process.env.PG_HOST || "localhost",
  port: parseInt(process.env.PG_PORT || "5432"),
  user: "bench",
  password: "bench",
  database: "bench",
});

async function bench(label: string, fn: () => Promise<void>, ops: number) {
  const start = performance.now();
  for (let i = 0; i < ops; i++) {
    await fn();
  }
  const elapsed = performance.now() - start;
  const opsPerSec = (ops / (elapsed / 1000)).toFixed(2);
  console.log(`${label}: ${opsPerSec} ops/sec (${elapsed.toFixed(2)}ms for ${ops} ops)`);
  return { label, ops, elapsed_ms: elapsed, ops_per_sec: parseFloat(opsPerSec) };
}

async function main() {
  await client.connect();

  // Warmup
  console.log(`Warming up (${WARMUP_OPS} ops per operation)...`);
  for (let i = 0; i < WARMUP_OPS; i++) {
    await client.query("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", [`warm${i}`, `warm${i}@test.com`]);
  }
  await client.query("TRUNCATE users RESTART IDENTITY");

  // Measure
  console.log(`Measuring (${MEASURE_OPS} ops per operation)...`);
  const results: Record<string, unknown>[] = [];

  // INSERT
  results.push(await bench("INSERT", async () => {
    await client.query("INSERT INTO users (name, email) VALUES ($1, $2)", ["John Doe", `john${Math.random()}@test.com`]);
  }, MEASURE_OPS));

  // SELECT
  const { rows: [{ id: selectId }] } = await client.query("SELECT id FROM users LIMIT 1");
  results.push(await bench("SELECT", async () => {
    await client.query("SELECT * FROM users WHERE id = $1", [selectId]);
  }, MEASURE_OPS));

  // UPDATE
  results.push(await bench("UPDATE", async () => {
    await client.query("UPDATE users SET name = $1 WHERE id = $2", ["Jane Doe", selectId]);
  }, MEASURE_OPS));

  // DELETE (insert then delete)
  results.push(await bench("DELETE", async () => {
    const { rows: [{ id }] } = await client.query("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", ["temp", `temp${Math.random()}@test.com`]);
    await client.query("DELETE FROM users WHERE id = $1", [id]);
  }, MEASURE_OPS));

  console.log(JSON.stringify({ runtime: "node", driver: "pg", results }, null, 2));
  await client.end();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 3: Create Bun DB benchmarks (standard + native)**

`benchmarks/02-db-crud/bun/package.json`
```json
{
  "name": "db-crud-bun",
  "private": true,
  "type": "module",
  "dependencies": {
    "pg": "^8.13.0"
  }
}
```

`benchmarks/02-db-crud/bun/bench-pg.ts`
```typescript
import pg from "pg";
const { Client } = pg;

const WARMUP_OPS = 1000;
const MEASURE_OPS = 10000;

const client = new Client({
  host: process.env.PG_HOST || "localhost",
  port: parseInt(process.env.PG_PORT || "5432"),
  user: "bench",
  password: "bench",
  database: "bench",
});

async function bench(label: string, fn: () => Promise<void>, ops: number) {
  const start = performance.now();
  for (let i = 0; i < ops; i++) {
    await fn();
  }
  const elapsed = performance.now() - start;
  const opsPerSec = (ops / (elapsed / 1000)).toFixed(2);
  console.log(`${label}: ${opsPerSec} ops/sec (${elapsed.toFixed(2)}ms for ${ops} ops)`);
  return { label, ops, elapsed_ms: elapsed, ops_per_sec: parseFloat(opsPerSec) };
}

async function main() {
  await client.connect();

  console.log(`Warming up (${WARMUP_OPS} ops)...`);
  for (let i = 0; i < WARMUP_OPS; i++) {
    await client.query("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", [`warm${i}`, `warm${i}@test.com`]);
  }
  await client.query("TRUNCATE users RESTART IDENTITY");

  console.log(`Measuring (${MEASURE_OPS} ops per operation)...`);
  const results: Record<string, unknown>[] = [];

  results.push(await bench("INSERT", async () => {
    await client.query("INSERT INTO users (name, email) VALUES ($1, $2)", ["John Doe", `john${Math.random()}@test.com`]);
  }, MEASURE_OPS));

  const { rows: [{ id: selectId }] } = await client.query("SELECT id FROM users LIMIT 1");
  results.push(await bench("SELECT", async () => {
    await client.query("SELECT * FROM users WHERE id = $1", [selectId]);
  }, MEASURE_OPS));

  results.push(await bench("UPDATE", async () => {
    await client.query("UPDATE users SET name = $1 WHERE id = $2", ["Jane Doe", selectId]);
  }, MEASURE_OPS));

  results.push(await bench("DELETE", async () => {
    const { rows: [{ id }] } = await client.query("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", ["temp", `temp${Math.random()}@test.com`]);
    await client.query("DELETE FROM users WHERE id = $1", [id]);
  }, MEASURE_OPS));

  console.log(JSON.stringify({ runtime: "bun", driver: "pg", results }, null, 2));
  await client.end();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

`benchmarks/02-db-crud/bun/bench-native.ts`
```typescript
import { SQL } from "bun";

const WARMUP_OPS = 1000;
const MEASURE_OPS = 10000;

const sql = new SQL({
  hostname: process.env.PG_HOST || "localhost",
  port: parseInt(process.env.PG_PORT || "5432"),
  username: "bench",
  password: "bench",
  database: "bench",
});

async function bench(label: string, fn: () => Promise<void>, ops: number) {
  const start = performance.now();
  for (let i = 0; i < ops; i++) {
    await fn();
  }
  const elapsed = performance.now() - start;
  const opsPerSec = (ops / (elapsed / 1000)).toFixed(2);
  console.log(`${label}: ${opsPerSec} ops/sec (${elapsed.toFixed(2)}ms for ${ops} ops)`);
  return { label, ops, elapsed_ms: elapsed, ops_per_sec: parseFloat(opsPerSec) };
}

async function main() {
  console.log(`Warming up (${WARMUP_OPS} ops)...`);
  for (let i = 0; i < WARMUP_OPS; i++) {
    await sql`INSERT INTO users (name, email) VALUES (${"warm" + i}, ${"warm" + i + "@test.com"}) RETURNING id`;
  }
  await sql`TRUNCATE users RESTART IDENTITY`;

  console.log(`Measuring (${MEASURE_OPS} ops per operation)...`);
  const results: Record<string, unknown>[] = [];

  results.push(await bench("INSERT", async () => {
    const name = "John Doe";
    const email = `john${Math.random()}@test.com`;
    await sql`INSERT INTO users (name, email) VALUES (${name}, ${email})`;
  }, MEASURE_OPS));

  const [{ id: selectId }] = await sql`SELECT id FROM users LIMIT 1`;
  results.push(await bench("SELECT", async () => {
    await sql`SELECT * FROM users WHERE id = ${selectId}`;
  }, MEASURE_OPS));

  results.push(await bench("UPDATE", async () => {
    const name = "Jane Doe";
    await sql`UPDATE users SET name = ${name} WHERE id = ${selectId}`;
  }, MEASURE_OPS));

  results.push(await bench("DELETE", async () => {
    const name = "temp";
    const email = `temp${Math.random()}@test.com`;
    const [{ id }] = await sql`INSERT INTO users (name, email) VALUES (${name}, ${email}) RETURNING id`;
    await sql`DELETE FROM users WHERE id = ${id}`;
  }, MEASURE_OPS));

  console.log(JSON.stringify({ runtime: "bun", driver: "bun:sql", results }, null, 2));
  sql.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 4: Create Deno DB benchmark**

`benchmarks/02-db-crud/deno/deno.json`
```json
{
  "imports": {
    "postgres": "https://deno.land/x/postgres@v0.19.3/mod.ts"
  }
}
```

`benchmarks/02-db-crud/deno/bench.ts`
```typescript
import { Client } from "postgres";

const WARMUP_OPS = 1000;
const MEASURE_OPS = 10000;

const client = new Client({
  hostname: Deno.env.get("PG_HOST") || "localhost",
  port: parseInt(Deno.env.get("PG_PORT") || "5432"),
  user: "bench",
  password: "bench",
  database: "bench",
});

async function bench(label: string, fn: () => Promise<void>, ops: number) {
  const start = performance.now();
  for (let i = 0; i < ops; i++) {
    await fn();
  }
  const elapsed = performance.now() - start;
  const opsPerSec = (ops / (elapsed / 1000)).toFixed(2);
  console.log(`${label}: ${opsPerSec} ops/sec (${elapsed.toFixed(2)}ms for ${ops} ops)`);
  return { label, ops, elapsed_ms: elapsed, ops_per_sec: parseFloat(opsPerSec) };
}

async function main() {
  await client.connect();

  console.log(`Warming up (${WARMUP_OPS} ops)...`);
  for (let i = 0; i < WARMUP_OPS; i++) {
    await client.queryObject("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", [`warm${i}`, `warm${i}@test.com`]);
  }
  await client.queryObject("TRUNCATE users RESTART IDENTITY");

  console.log(`Measuring (${MEASURE_OPS} ops per operation)...`);
  const results: Record<string, unknown>[] = [];

  results.push(await bench("INSERT", async () => {
    await client.queryObject("INSERT INTO users (name, email) VALUES ($1, $2)", ["John Doe", `john${Math.random()}@test.com`]);
  }, MEASURE_OPS));

  const { rows: [{ id: selectId }] } = await client.queryObject<{ id: number }>("SELECT id FROM users LIMIT 1");
  results.push(await bench("SELECT", async () => {
    await client.queryObject("SELECT * FROM users WHERE id = $1", [selectId]);
  }, MEASURE_OPS));

  results.push(await bench("UPDATE", async () => {
    await client.queryObject("UPDATE users SET name = $1 WHERE id = $2", ["Jane Doe", selectId]);
  }, MEASURE_OPS));

  results.push(await bench("DELETE", async () => {
    const { rows: [{ id }] } = await client.queryObject<{ id: number }>("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", ["temp", `temp${Math.random()}@test.com`]);
    await client.queryObject("DELETE FROM users WHERE id = $1", [id]);
  }, MEASURE_OPS));

  console.log(JSON.stringify({ runtime: "deno", driver: "deno-postgres", results }, null, 2));
  await client.end();
}

main().catch((err) => {
  console.error(err);
  Deno.exit(1);
});
```

- [ ] **Step 5: Create Elide DB benchmark**

`benchmarks/02-db-crud/elide/bench.ts`
```typescript
// NOTE: Elide's built-in postgres driver API is not fully documented.
// This is a best-effort implementation based on available docs.
// May need adjustment once we test against a real Elide install.
// If elide:postgres doesn't work, fall back to npm pg driver.

import pg from "pg";
const { Client } = pg;

const WARMUP_OPS = 1000;
const MEASURE_OPS = 10000;

const client = new Client({
  host: process.env.PG_HOST || "localhost",
  port: parseInt(process.env.PG_PORT || "5432"),
  user: "bench",
  password: "bench",
  database: "bench",
});

async function bench(label: string, fn: () => Promise<void>, ops: number) {
  const start = performance.now();
  for (let i = 0; i < ops; i++) {
    await fn();
  }
  const elapsed = performance.now() - start;
  const opsPerSec = (ops / (elapsed / 1000)).toFixed(2);
  console.log(`${label}: ${opsPerSec} ops/sec (${elapsed.toFixed(2)}ms for ${ops} ops)`);
  return { label, ops, elapsed_ms: elapsed, ops_per_sec: parseFloat(opsPerSec) };
}

async function main() {
  await client.connect();

  console.log(`Warming up (${WARMUP_OPS} ops)...`);
  for (let i = 0; i < WARMUP_OPS; i++) {
    await client.query("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", [`warm${i}`, `warm${i}@test.com`]);
  }
  await client.query("TRUNCATE users RESTART IDENTITY");

  console.log(`Measuring (${MEASURE_OPS} ops per operation)...`);
  const results: Record<string, unknown>[] = [];

  results.push(await bench("INSERT", async () => {
    await client.query("INSERT INTO users (name, email) VALUES ($1, $2)", ["John Doe", `john${Math.random()}@test.com`]);
  }, MEASURE_OPS));

  const { rows: [{ id: selectId }] } = await client.query("SELECT id FROM users LIMIT 1");
  results.push(await bench("SELECT", async () => {
    await client.query("SELECT * FROM users WHERE id = $1", [selectId]);
  }, MEASURE_OPS));

  results.push(await bench("UPDATE", async () => {
    await client.query("UPDATE users SET name = $1 WHERE id = $2", ["Jane Doe", selectId]);
  }, MEASURE_OPS));

  results.push(await bench("DELETE", async () => {
    const { rows: [{ id }] } = await client.query("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id", ["temp", `temp${Math.random()}@test.com`]);
    await client.query("DELETE FROM users WHERE id = $1", [id]);
  }, MEASURE_OPS));

  console.log(JSON.stringify({ runtime: "elide", driver: "pg (fallback)", results }, null, 2));
  await client.end();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 6: Install deps and verify one benchmark connects to PG**

```bash
(cd benchmarks/02-db-crud/node && npm install)
(cd benchmarks/02-db-crud/bun && bun install)
docker compose up -d
PGPASSWORD=bench psql -h localhost -U bench -d bench -f benchmarks/02-db-crud/schema.sql
(cd benchmarks/02-db-crud/node && npx tsx bench.ts)
```

- [ ] **Step 7: Commit**

```bash
git add benchmarks/02-db-crud/
git commit -m "feat: add DB CRUD benchmarks for node, bun (pg + native), deno, elide"
```

---

## Task 5: DB CRUD Run Script

**Files:**
- Create: `benchmarks/02-db-crud/run.sh`

- [ ] **Step 1: Create `run.sh`**

`benchmarks/02-db-crud/run.sh`
```bash
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
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x benchmarks/02-db-crud/run.sh
benchmarks/02-db-crud/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add benchmarks/02-db-crud/run.sh
git commit -m "feat: add run script for DB CRUD benchmark"
```

---

## Task 6: Micro-benchmarks (JSON + Crypto)

> **Spec deviation:** The spec defines per-runtime files (e.g., `json/node.ts`, `json/bun.ts`). This plan uses a single runtime-agnostic `bench.ts` per category instead, since the benchmarks use standard Web APIs (`JSON`, `crypto.subtle`, `performance`) available in all 4 runtimes. The `run.sh` invokes each runtime against the same file. This reduces duplication without sacrificing accuracy.

**Files:**
- Create: `benchmarks/04-micro-benchmarks/json/bench.ts`
- Create: `benchmarks/04-micro-benchmarks/crypto/bench.ts`
- Create: `benchmarks/04-micro-benchmarks/run.sh`

- [ ] **Step 1: Create JSON benchmark**

`benchmarks/04-micro-benchmarks/json/bench.ts`
```typescript
// Runtime-agnostic JSON benchmark
// Run with: node --import tsx/esm, bun, deno run, or elide

const ITERATIONS = 1_000_000;

// ~1KB JSON object
const testObject = {
  id: 12345,
  name: "John Doe",
  email: "john@example.com",
  active: true,
  roles: ["admin", "user", "editor"],
  metadata: {
    lastLogin: "2026-03-25T10:00:00Z",
    loginCount: 42,
    preferences: {
      theme: "dark",
      language: "en",
      notifications: true,
    },
  },
  tags: ["important", "verified", "premium"],
};

const jsonString = JSON.stringify(testObject);

// Warmup
for (let i = 0; i < 10_000; i++) {
  JSON.parse(jsonString);
  JSON.stringify(testObject);
}

// Benchmark JSON.parse
const parseStart = performance.now();
for (let i = 0; i < ITERATIONS; i++) {
  JSON.parse(jsonString);
}
const parseElapsed = performance.now() - parseStart;
const parseOps = (ITERATIONS / (parseElapsed / 1000)).toFixed(2);

// Benchmark JSON.stringify
const stringifyStart = performance.now();
for (let i = 0; i < ITERATIONS; i++) {
  JSON.stringify(testObject);
}
const stringifyElapsed = performance.now() - stringifyStart;
const stringifyOps = (ITERATIONS / (stringifyElapsed / 1000)).toFixed(2);

console.log(`JSON.parse:     ${parseOps} ops/sec (${parseElapsed.toFixed(2)}ms)`);
console.log(`JSON.stringify: ${stringifyOps} ops/sec (${stringifyElapsed.toFixed(2)}ms)`);
console.log(JSON.stringify({
  benchmark: "json",
  iterations: ITERATIONS,
  results: {
    parse: { ops_per_sec: parseFloat(parseOps), elapsed_ms: parseElapsed },
    stringify: { ops_per_sec: parseFloat(stringifyOps), elapsed_ms: stringifyElapsed },
  },
}));
```

- [ ] **Step 2: Create crypto benchmark**

`benchmarks/04-micro-benchmarks/crypto/bench.ts`
```typescript
// Runtime-agnostic crypto benchmark
// Uses Web Crypto API (available in all 4 runtimes)

const HASH_ITERATIONS = 100_000;
const UUID_ITERATIONS = 1_000_000;

const encoder = new TextEncoder();
const data = encoder.encode("Hello, World! This is a benchmark string for SHA-256 hashing.");

// Warmup
for (let i = 0; i < 1000; i++) {
  await crypto.subtle.digest("SHA-256", data);
  crypto.randomUUID();
}

// Benchmark SHA-256
const hashStart = performance.now();
for (let i = 0; i < HASH_ITERATIONS; i++) {
  await crypto.subtle.digest("SHA-256", data);
}
const hashElapsed = performance.now() - hashStart;
const hashOps = (HASH_ITERATIONS / (hashElapsed / 1000)).toFixed(2);

// Benchmark randomUUID
const uuidStart = performance.now();
for (let i = 0; i < UUID_ITERATIONS; i++) {
  crypto.randomUUID();
}
const uuidElapsed = performance.now() - uuidStart;
const uuidOps = (UUID_ITERATIONS / (uuidElapsed / 1000)).toFixed(2);

console.log(`SHA-256:    ${hashOps} ops/sec (${hashElapsed.toFixed(2)}ms for ${HASH_ITERATIONS} ops)`);
console.log(`randomUUID: ${uuidOps} ops/sec (${uuidElapsed.toFixed(2)}ms for ${UUID_ITERATIONS} ops)`);
console.log(JSON.stringify({
  benchmark: "crypto",
  results: {
    sha256: { iterations: HASH_ITERATIONS, ops_per_sec: parseFloat(hashOps), elapsed_ms: hashElapsed },
    randomUUID: { iterations: UUID_ITERATIONS, ops_per_sec: parseFloat(uuidOps), elapsed_ms: uuidElapsed },
  },
}));
```

- [ ] **Step 3: Create run script**

`benchmarks/04-micro-benchmarks/run.sh`
```bash
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
```

- [ ] **Step 4: Make executable and quick test**

```bash
chmod +x benchmarks/04-micro-benchmarks/run.sh
npx tsx benchmarks/04-micro-benchmarks/json/bench.ts
```

- [ ] **Step 5: Commit**

```bash
git add benchmarks/04-micro-benchmarks/
git commit -m "feat: add JSON and crypto micro-benchmarks"
```

---

## Task 7: Next.js Serving Benchmark

**Files:**
- Create: `benchmarks/03-nextjs-serving/app/` (scaffolded)
- Create: `benchmarks/03-nextjs-serving/run.sh`

- [ ] **Step 1: Scaffold Next.js app**

```bash
cd benchmarks/03-nextjs-serving
npx create-next-app@latest app --ts --tailwind --eslint --app --no-src-dir --import-alias "@/*" --use-npm
```

- [ ] **Step 2: Build the app once**

```bash
cd benchmarks/03-nextjs-serving/app
npm run build
```

- [ ] **Step 3: Create run script**

`benchmarks/03-nextjs-serving/run.sh`
```bash
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
```

- [ ] **Step 4: Make executable**

```bash
chmod +x benchmarks/03-nextjs-serving/run.sh
```

- [ ] **Step 5: Test that Node serves the app**

```bash
cd benchmarks/03-nextjs-serving/app && PORT=3000 npx next start -p 3000
# Verify in another terminal: curl http://localhost:3000
```

- [ ] **Step 6: Commit**

```bash
git add benchmarks/03-nextjs-serving/
git commit -m "feat: add Next.js serving benchmark with run script"
```

---

## Task 8: Polyglot vs Native — Python

**Files:**
- Create: `benchmarks/05-polyglot-vs-native/cpython/http-server.py`
- Create: `benchmarks/05-polyglot-vs-native/cpython/db-crud.py`
- Create: `benchmarks/05-polyglot-vs-native/cpython/requirements.txt`
- Create: `benchmarks/05-polyglot-vs-native/elide-python/http-server.py`
- Create: `benchmarks/05-polyglot-vs-native/elide-python/db-crud.py`

- [ ] **Step 1: Create CPython HTTP server**

`benchmarks/05-polyglot-vs-native/cpython/requirements.txt`
```
psycopg2-binary>=2.9.9
uvicorn>=0.30.0
```

`benchmarks/05-polyglot-vs-native/cpython/http-server.py`
```python
"""Minimal HTTP server using built-in http.server for fair comparison."""
import os
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("PORT", "3000"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Hello, World!")

    def log_message(self, format, *args):
        pass  # suppress request logging for benchmark

if __name__ == "__main__":
    server = HTTPServer(("", PORT), Handler)
    print(f"CPython listening on port {PORT}")
    server.serve_forever()
```

- [ ] **Step 2: Create CPython DB CRUD benchmark**

`benchmarks/05-polyglot-vs-native/cpython/db-crud.py`
```python
"""PostgreSQL CRUD benchmark using psycopg2."""
import os
import time
import json
import random
import psycopg2

WARMUP_OPS = 1000
MEASURE_OPS = 10000

conn = psycopg2.connect(
    host=os.environ.get("PG_HOST", "localhost"),
    port=int(os.environ.get("PG_PORT", "5432")),
    user="bench",
    password="bench",
    dbname="bench",
)
conn.autocommit = True
cur = conn.cursor()

def bench(label, fn, ops):
    start = time.perf_counter()
    for _ in range(ops):
        fn()
    elapsed = (time.perf_counter() - start) * 1000  # ms
    ops_per_sec = ops / (elapsed / 1000)
    print(f"{label}: {ops_per_sec:.2f} ops/sec ({elapsed:.2f}ms for {ops} ops)")
    return {"label": label, "ops": ops, "elapsed_ms": elapsed, "ops_per_sec": round(ops_per_sec, 2)}

# Warmup
print(f"Warming up ({WARMUP_OPS} ops)...")
for i in range(WARMUP_OPS):
    cur.execute("INSERT INTO users (name, email) VALUES (%s, %s) RETURNING id", (f"warm{i}", f"warm{i}@test.com"))
cur.execute("TRUNCATE users RESTART IDENTITY")

print(f"Measuring ({MEASURE_OPS} ops per operation)...")
results = []

# INSERT
def do_insert():
    cur.execute("INSERT INTO users (name, email) VALUES (%s, %s)", ("John Doe", f"john{random.random()}@test.com"))
results.append(bench("INSERT", do_insert, MEASURE_OPS))

# SELECT
cur.execute("SELECT id FROM users LIMIT 1")
select_id = cur.fetchone()[0]
def do_select():
    cur.execute("SELECT * FROM users WHERE id = %s", (select_id,))
    cur.fetchone()
results.append(bench("SELECT", do_select, MEASURE_OPS))

# UPDATE
def do_update():
    cur.execute("UPDATE users SET name = %s WHERE id = %s", ("Jane Doe", select_id))
results.append(bench("UPDATE", do_update, MEASURE_OPS))

# DELETE
def do_delete():
    cur.execute("INSERT INTO users (name, email) VALUES (%s, %s) RETURNING id", ("temp", f"temp{random.random()}@test.com"))
    row_id = cur.fetchone()[0]
    cur.execute("DELETE FROM users WHERE id = %s", (row_id,))
results.append(bench("DELETE", do_delete, MEASURE_OPS))

print(json.dumps({"runtime": "cpython", "driver": "psycopg2", "results": results}, indent=2))
cur.close()
conn.close()
```

- [ ] **Step 3: Create Elide Python HTTP server**

`benchmarks/05-polyglot-vs-native/elide-python/http-server.py`
```python
"""HTTP server running on Elide's Python runtime.
NOTE: Elide added Python HTTP serving intrinsics in beta10.
This may need to use Elide's specific API. Adjust if needed."""
import os
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("PORT", "3000"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Hello, World!")

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    server = HTTPServer(("", PORT), Handler)
    print(f"Elide Python listening on port {PORT}")
    server.serve_forever()
```

- [ ] **Step 4: Create Elide Python DB CRUD benchmark**

`benchmarks/05-polyglot-vs-native/elide-python/db-crud.py`
```python
"""PostgreSQL CRUD benchmark running on Elide's Python runtime.
NOTE: May need Elide's built-in PG driver instead of psycopg2.
Adjust imports if needed after testing."""
import os
import time
import json
import random

# Try psycopg2 first; Elide may provide its own PG interface
try:
    import psycopg2
except ImportError:
    print("psycopg2 not available on Elide — need to use Elide's native PG driver")
    raise

WARMUP_OPS = 1000
MEASURE_OPS = 10000

conn = psycopg2.connect(
    host=os.environ.get("PG_HOST", "localhost"),
    port=int(os.environ.get("PG_PORT", "5432")),
    user="bench",
    password="bench",
    dbname="bench",
)
conn.autocommit = True
cur = conn.cursor()

def bench(label, fn, ops):
    start = time.perf_counter()
    for _ in range(ops):
        fn()
    elapsed = (time.perf_counter() - start) * 1000
    ops_per_sec = ops / (elapsed / 1000)
    print(f"{label}: {ops_per_sec:.2f} ops/sec ({elapsed:.2f}ms for {ops} ops)")
    return {"label": label, "ops": ops, "elapsed_ms": elapsed, "ops_per_sec": round(ops_per_sec, 2)}

print(f"Warming up ({WARMUP_OPS} ops)...")
for i in range(WARMUP_OPS):
    cur.execute("INSERT INTO users (name, email) VALUES (%s, %s) RETURNING id", (f"warm{i}", f"warm{i}@test.com"))
cur.execute("TRUNCATE users RESTART IDENTITY")

print(f"Measuring ({MEASURE_OPS} ops per operation)...")
results = []

def do_insert():
    cur.execute("INSERT INTO users (name, email) VALUES (%s, %s)", ("John Doe", f"john{random.random()}@test.com"))
results.append(bench("INSERT", do_insert, MEASURE_OPS))

cur.execute("SELECT id FROM users LIMIT 1")
select_id = cur.fetchone()[0]

def do_select():
    cur.execute("SELECT * FROM users WHERE id = %s", (select_id,))
    cur.fetchone()
results.append(bench("SELECT", do_select, MEASURE_OPS))

def do_update():
    cur.execute("UPDATE users SET name = %s WHERE id = %s", ("Jane Doe", select_id))
results.append(bench("UPDATE", do_update, MEASURE_OPS))

def do_delete():
    cur.execute("INSERT INTO users (name, email) VALUES (%s, %s) RETURNING id", ("temp", f"temp{random.random()}@test.com"))
    row_id = cur.fetchone()[0]
    cur.execute("DELETE FROM users WHERE id = %s", (row_id,))
results.append(bench("DELETE", do_delete, MEASURE_OPS))

print(json.dumps({"runtime": "elide-python", "driver": "psycopg2", "results": results}, indent=2))
cur.close()
conn.close()
```

- [ ] **Step 5: Commit**

```bash
git add benchmarks/05-polyglot-vs-native/cpython/ benchmarks/05-polyglot-vs-native/elide-python/
git commit -m "feat: add Python polyglot benchmarks (CPython vs Elide Python)"
```

---

## Task 9: Polyglot vs Native — Kotlin

**Files:**
- Create: `benchmarks/05-polyglot-vs-native/kotlin-jvm/http-server.kts`
- Create: `benchmarks/05-polyglot-vs-native/kotlin-jvm/db-crud.kts`
- Create: `benchmarks/05-polyglot-vs-native/elide-kotlin/http-server.kts`
- Create: `benchmarks/05-polyglot-vs-native/elide-kotlin/db-crud.kts`

- [ ] **Step 1: Create Kotlin/JVM HTTP server**

`benchmarks/05-polyglot-vs-native/kotlin-jvm/http-server.kts`
```kotlin
// Minimal HTTP server using com.sun.net.httpserver (JDK built-in)
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress

val port = System.getenv("PORT")?.toInt() ?: 3000
val server = HttpServer.create(InetSocketAddress(port), 0)

server.createContext("/") { exchange ->
    val response = "Hello, World!"
    exchange.sendResponseHeaders(200, response.length.toLong())
    exchange.responseBody.use { it.write(response.toByteArray()) }
}

println("Kotlin/JVM listening on port $port")
server.start()
```

- [ ] **Step 2: Create Kotlin/JVM DB CRUD benchmark**

`benchmarks/05-polyglot-vs-native/kotlin-jvm/db-crud.kts`
```kotlin
// PostgreSQL CRUD benchmark using JDBC
// Requires: postgresql JDBC driver on classpath
// Run: kotlin -cp postgresql-42.7.3.jar db-crud.kts

@file:DependsOn("org.postgresql:postgresql:42.7.3")

import java.sql.DriverManager

val WARMUP_OPS = 1000
val MEASURE_OPS = 10000

val host = System.getenv("PG_HOST") ?: "localhost"
val port = System.getenv("PG_PORT") ?: "5432"
val conn = DriverManager.getConnection("jdbc:postgresql://$host:$port/bench", "bench", "bench")
conn.autoCommit = true

fun bench(label: String, fn: () -> Unit, ops: Int): Map<String, Any> {
    val start = System.nanoTime()
    repeat(ops) { fn() }
    val elapsedMs = (System.nanoTime() - start) / 1_000_000.0
    val opsPerSec = ops / (elapsedMs / 1000.0)
    println("$label: ${"%.2f".format(opsPerSec)} ops/sec (${"%.2f".format(elapsedMs)}ms for $ops ops)")
    return mapOf("label" to label, "ops" to ops, "elapsed_ms" to elapsedMs, "ops_per_sec" to opsPerSec)
}

// Warmup
println("Warming up ($WARMUP_OPS ops)...")
val insertStmt = conn.prepareStatement("INSERT INTO users (name, email) VALUES (?, ?) RETURNING id")
repeat(WARMUP_OPS) { i ->
    insertStmt.setString(1, "warm$i")
    insertStmt.setString(2, "warm$i@test.com")
    insertStmt.executeQuery().close()
}
conn.createStatement().execute("TRUNCATE users RESTART IDENTITY")

println("Measuring ($MEASURE_OPS ops per operation)...")
val results = mutableListOf<Map<String, Any>>()

// INSERT
results.add(bench("INSERT", {
    insertStmt.setString(1, "John Doe")
    insertStmt.setString(2, "john${Math.random()}@test.com")
    insertStmt.executeQuery().close()
}, MEASURE_OPS))

// SELECT
val selectIdStmt = conn.prepareStatement("SELECT id FROM users LIMIT 1")
val rs = selectIdStmt.executeQuery()
rs.next()
val selectId = rs.getInt(1)
rs.close()

val selectStmt = conn.prepareStatement("SELECT * FROM users WHERE id = ?")
results.add(bench("SELECT", {
    selectStmt.setInt(1, selectId)
    selectStmt.executeQuery().close()
}, MEASURE_OPS))

// UPDATE
val updateStmt = conn.prepareStatement("UPDATE users SET name = ? WHERE id = ?")
results.add(bench("UPDATE", {
    updateStmt.setString(1, "Jane Doe")
    updateStmt.setInt(2, selectId)
    updateStmt.executeUpdate()
}, MEASURE_OPS))

// DELETE
val insertForDelete = conn.prepareStatement("INSERT INTO users (name, email) VALUES (?, ?) RETURNING id")
val deleteStmt = conn.prepareStatement("DELETE FROM users WHERE id = ?")
results.add(bench("DELETE", {
    insertForDelete.setString(1, "temp")
    insertForDelete.setString(2, "temp${Math.random()}@test.com")
    val delRs = insertForDelete.executeQuery()
    delRs.next()
    val id = delRs.getInt(1)
    delRs.close()
    deleteStmt.setInt(1, id)
    deleteStmt.executeUpdate()
}, MEASURE_OPS))

println("""{"runtime": "kotlin-jvm", "driver": "jdbc", "results": $results}""")
conn.close()
```

- [ ] **Step 3: Create Elide Kotlin HTTP server**

`benchmarks/05-polyglot-vs-native/elide-kotlin/http-server.kts`
```kotlin
// HTTP server running on Elide's Kotlin runtime
// NOTE: Elide runs .kts scripts natively. May need Elide-specific HTTP API.
// Attempting JDK built-in first; adjust if Elide exposes its own API.

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress

val port = System.getenv("PORT")?.toInt() ?: 3000
val server = HttpServer.create(InetSocketAddress(port), 0)

server.createContext("/") { exchange ->
    val response = "Hello, World!"
    exchange.sendResponseHeaders(200, response.length.toLong())
    exchange.responseBody.use { it.write(response.toByteArray()) }
}

println("Elide Kotlin listening on port $port")
server.start()
```

- [ ] **Step 4: Create Elide Kotlin DB CRUD benchmark**

`benchmarks/05-polyglot-vs-native/elide-kotlin/db-crud.kts`
```kotlin
// PostgreSQL CRUD benchmark running on Elide's Kotlin runtime
// NOTE: Elide may provide its own native PG driver for Kotlin.
// Starting with JDBC; adjust if Elide has a better interface.

@file:DependsOn("org.postgresql:postgresql:42.7.3")

import java.sql.DriverManager

val WARMUP_OPS = 1000
val MEASURE_OPS = 10000

val host = System.getenv("PG_HOST") ?: "localhost"
val port = System.getenv("PG_PORT") ?: "5432"
val conn = DriverManager.getConnection("jdbc:postgresql://$host:$port/bench", "bench", "bench")
conn.autoCommit = true

fun bench(label: String, fn: () -> Unit, ops: Int): Map<String, Any> {
    val start = System.nanoTime()
    repeat(ops) { fn() }
    val elapsedMs = (System.nanoTime() - start) / 1_000_000.0
    val opsPerSec = ops / (elapsedMs / 1000.0)
    println("$label: ${"%.2f".format(opsPerSec)} ops/sec (${"%.2f".format(elapsedMs)}ms for $ops ops)")
    return mapOf("label" to label, "ops" to ops, "elapsed_ms" to elapsedMs, "ops_per_sec" to opsPerSec)
}

println("Warming up ($WARMUP_OPS ops)...")
val insertStmt = conn.prepareStatement("INSERT INTO users (name, email) VALUES (?, ?) RETURNING id")
repeat(WARMUP_OPS) { i ->
    insertStmt.setString(1, "warm$i")
    insertStmt.setString(2, "warm$i@test.com")
    insertStmt.executeQuery().close()
}
conn.createStatement().execute("TRUNCATE users RESTART IDENTITY")

println("Measuring ($MEASURE_OPS ops per operation)...")
val results = mutableListOf<Map<String, Any>>()

results.add(bench("INSERT", {
    insertStmt.setString(1, "John Doe")
    insertStmt.setString(2, "john${Math.random()}@test.com")
    insertStmt.executeQuery().close()
}, MEASURE_OPS))

val selectIdStmt = conn.prepareStatement("SELECT id FROM users LIMIT 1")
val rs = selectIdStmt.executeQuery()
rs.next()
val selectId = rs.getInt(1)
rs.close()

val selectStmt = conn.prepareStatement("SELECT * FROM users WHERE id = ?")
results.add(bench("SELECT", {
    selectStmt.setInt(1, selectId)
    selectStmt.executeQuery().close()
}, MEASURE_OPS))

val updateStmt = conn.prepareStatement("UPDATE users SET name = ? WHERE id = ?")
results.add(bench("UPDATE", {
    updateStmt.setString(1, "Jane Doe")
    updateStmt.setInt(2, selectId)
    updateStmt.executeUpdate()
}, MEASURE_OPS))

val insertForDelete = conn.prepareStatement("INSERT INTO users (name, email) VALUES (?, ?) RETURNING id")
val deleteStmt = conn.prepareStatement("DELETE FROM users WHERE id = ?")
results.add(bench("DELETE", {
    insertForDelete.setString(1, "temp")
    insertForDelete.setString(2, "temp${Math.random()}@test.com")
    val delRs = insertForDelete.executeQuery()
    delRs.next()
    val id = delRs.getInt(1)
    delRs.close()
    deleteStmt.setInt(1, id)
    deleteStmt.executeUpdate()
}, MEASURE_OPS))

println("""{"runtime": "elide-kotlin", "driver": "jdbc", "results": $results}""")
conn.close()
```

- [ ] **Step 5: Commit**

```bash
git add benchmarks/05-polyglot-vs-native/kotlin-jvm/ benchmarks/05-polyglot-vs-native/elide-kotlin/
git commit -m "feat: add Kotlin polyglot benchmarks (JVM vs Elide Kotlin)"
```

---

## Task 10: Polyglot Run Script

**Files:**
- Create: `benchmarks/05-polyglot-vs-native/run.sh`

- [ ] **Step 1: Create run script**

`benchmarks/05-polyglot-vs-native/run.sh`
```bash
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

log_info "=== Polyglot vs Native Benchmark ==="

# Ensure PG is running
if ! pg_isready -h localhost -U bench -d bench > /dev/null 2>&1; then
    log_info "Starting PostgreSQL..."
    docker compose -f "${PROJECT_ROOT}/docker-compose.yml" up -d
    sleep 3
fi

# Install Python deps for CPython
if [ -f "${SCRIPT_DIR}/cpython/requirements.txt" ]; then
    log_info "Installing CPython dependencies..."
    pip install -r "${SCRIPT_DIR}/cpython/requirements.txt" -q
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

http_bench "cpython" "PORT=${PORT} python3 ${SCRIPT_DIR}/cpython/http-server.py"
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

db_bench "cpython" "python3 ${SCRIPT_DIR}/cpython/db-crud.py"
db_bench "elide-python" "elide ${SCRIPT_DIR}/elide-python/db-crud.py"
db_bench "kotlin-jvm" "kotlin ${SCRIPT_DIR}/kotlin-jvm/db-crud.kts"
db_bench "elide-kotlin" "elide ${SCRIPT_DIR}/elide-kotlin/db-crud.kts"

log_ok "Polyglot vs Native benchmark complete"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x benchmarks/05-polyglot-vs-native/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add benchmarks/05-polyglot-vs-native/run.sh
git commit -m "feat: add run script for polyglot vs native benchmarks"
```

---

## Task 11: Setup and Orchestration Scripts

**Files:**
- Create: `scripts/setup.sh`
- Create: `scripts/run-all.sh`
- Create: `scripts/collect-results.sh`

- [ ] **Step 1: Create `scripts/setup.sh`**

`scripts/setup.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/bench-utils.sh"

log_info "=== Runtime Benchmark Suite Setup ==="

# System deps
log_info "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential libssl-dev git curl wget unzip \
    postgresql-client lsof bc

# wrk2
if ! command -v wrk2 &> /dev/null; then
    log_info "Installing wrk2..."
    cd /tmp
    git clone https://github.com/giltene/wrk2.git
    cd wrk2
    make -j$(nproc)
    sudo cp wrk /usr/local/bin/wrk2
    cd -
    log_ok "wrk2 installed"
else
    log_ok "wrk2 already installed"
fi

# Node.js (via nvm)
if ! command -v node &> /dev/null; then
    log_info "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
log_ok "Node.js: $(node --version)"

# tsx (for running TS with Node)
if ! command -v tsx &> /dev/null; then
    npm install -g tsx
fi

# Bun
if ! command -v bun &> /dev/null; then
    log_info "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
fi
log_ok "Bun: $(bun --version)"

# Deno
if ! command -v deno &> /dev/null; then
    log_info "Installing Deno..."
    curl -fsSL https://deno.land/install.sh | sh
fi
log_ok "Deno: $(deno --version | head -1)"

# Elide
if ! command -v elide &> /dev/null; then
    log_info "Installing Elide..."
    curl -sSL https://elide.sh | bash
fi
log_ok "Elide: $(elide --version 2>/dev/null || echo 'installed (version check may vary)')"

# Docker
if ! command -v docker &> /dev/null; then
    log_warn "Docker is not installed. Please install Docker manually."
    log_warn "See: https://docs.docker.com/engine/install/ubuntu/"
else
    log_ok "Docker: $(docker --version)"
fi

# Kotlin
if ! command -v kotlin &> /dev/null; then
    log_info "Installing Kotlin..."
    curl -s https://get.sdkman.io | bash
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    sdk install kotlin
fi
log_ok "Kotlin: $(kotlin -version 2>&1 | head -1)"

# Python deps
log_info "Installing Python dependencies..."
pip install psycopg2-binary uvicorn -q 2>/dev/null || pip3 install psycopg2-binary uvicorn -q

# Install benchmark JS deps
log_info "Installing JS dependencies..."
(cd "${PROJECT_ROOT}/benchmarks/02-db-crud/node" && npm install --silent)
(cd "${PROJECT_ROOT}/benchmarks/02-db-crud/bun" && bun install --silent)

log_info ""
log_info "=== Version Summary ==="
runtime_versions_json
log_ok "Setup complete!"
```

- [ ] **Step 2: Create `scripts/run-all.sh`**

`scripts/run-all.sh`
```bash
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

WRK_RATE="${WRK_RATE:-50000}"

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
```

- [ ] **Step 3: Create `scripts/collect-results.sh`**

`scripts/collect-results.sh`
```bash
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
```

- [ ] **Step 4: Make all scripts executable**

```bash
chmod +x scripts/setup.sh scripts/run-all.sh scripts/collect-results.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/ lib/
git commit -m "feat: add setup, run-all, and collect-results scripts"
```

---

## Task 12: Final Integration Verification

- [ ] **Step 1: Verify the full directory structure matches the spec**

```bash
find . -type f | grep -v node_modules | grep -v .git | grep -v .next | sort
```

Compare against the file map at the top of this plan.

- [ ] **Step 2: Run a quick smoke test of each benchmark category**

```bash
# HTTP (just verify server starts)
PORT=3001 npx tsx benchmarks/01-http-hello-world/node/server.ts &
curl -s http://localhost:3001/ && echo " — OK"
kill %1

# Micro-benchmark (quick run)
npx tsx benchmarks/04-micro-benchmarks/json/bench.ts

# DB (if PG is running)
docker compose up -d
PGPASSWORD=bench psql -h localhost -U bench -d bench -f benchmarks/02-db-crud/schema.sql
npx tsx benchmarks/02-db-crud/node/bench.ts
```

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration fixes from smoke testing"
```

- [ ] **Step 4: Tag the initial version**

```bash
git tag v0.1.0
```
