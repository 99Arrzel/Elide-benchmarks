# Elide Runtime Comparisons

An independent benchmark comparing **Elide**, **Node.js**, **Bun**, and **Deno** across HTTP performance, database operations, JSON/crypto micro-benchmarks, Next.js serving, and Elide's polyglot capabilities (Python, Kotlin).

## Why?

Elide claims up to 800K RPS on TechEmpower and 75x faster than Node v20. These are marketing numbers. This project runs independent, reproducible benchmarks to see what the real-world differences look like across practical use cases.

## Runtimes

| Runtime | Engine | Version |
|---------|--------|---------|
| [Node.js](https://nodejs.org/) | V8 | Latest LTS |
| [Bun](https://bun.sh/) | JavaScriptCore | Latest stable |
| [Deno](https://deno.com/) | V8 | Latest stable |
| [Elide](https://elide.dev/) | GraalVM/Truffle | Latest beta |

## Benchmark Categories

### 1. HTTP Hello World
Minimal HTTP server returning plain text. Each runtime uses its built-in HTTP API — no frameworks.

### 2. Database CRUD (PostgreSQL)
INSERT, SELECT, UPDATE, DELETE operations against PostgreSQL 16. Tests both "standard" community drivers and native/built-in drivers where available.

| Runtime | Standard Driver | Native Driver |
|---------|----------------|---------------|
| Node | `pg` (node-postgres) | — |
| Bun | `pg` (node-postgres) | `Bun.sql` |
| Deno | `deno-postgres` | — |
| Elide | — | `elide:postgres` (built-in) |

### 3. Next.js Serving
A vanilla Next.js app (latest version, no extra libraries) is built once with Node, then served by each runtime. This measures the runtime's serving performance, not Next.js build speed (which uses SWC/Turbopack internally and is runtime-agnostic).

### 4. Micro-benchmarks
- **JSON:** `JSON.parse()` / `JSON.stringify()` throughput
- **Crypto:** SHA-256 hashing, `crypto.randomUUID()` throughput

### 5. Polyglot vs Native
Elide's polyglot runtime running Python and Kotlin compared against their native counterparts (CPython, Kotlin/JVM). Runs the same HTTP and DB benchmarks to measure the overhead (or lack thereof) of running inside GraalVM.

## Methodology

### Load Testing
- **Tool:** [wrk2](https://github.com/giltene/wrk2) (constant-throughput, avoids coordinated omission)
- **Protocol:** 10s warmup, 30s measurement, 3 runs per config (report median)
- **Metrics:** req/s, latency p50/p95/p99, error rate

### Database Benchmarks
- Warmup phase (1,000 ops), measurement phase (10,000+ ops)
- Single connection (no pooling) for fair comparison
- 3 runs per config, report median

### Memory
- RSS measured via `ps -o rss` at idle and under load

### Environment
- **Runtimes:** Bare metal on Ubuntu server
- **PostgreSQL:** Docker container (`postgres:16`) with pinned config
- **Isolation:** One runtime at a time, clean state between runs

## PostgreSQL Configuration

The `postgres/postgresql.conf` is committed and documented. Key settings:

```
shared_buffers = 256MB
work_mem = 16MB
max_connections = 100
effective_cache_size = 768MB
```

> These are intentionally moderate defaults. The goal is measuring runtime driver performance, not tuning PostgreSQL. The config is committed so results are reproducible.

## Project Structure

```
elide-comparisons/
├── README.md
├── TODO.md
├── docker-compose.yml              # PostgreSQL only
├── postgres/
│   └── postgresql.conf
├── benchmarks/
│   ├── 01-http-hello-world/
│   │   ├── node/ bun/ deno/ elide/
│   │   └── run.sh
│   ├── 02-db-crud/
│   │   ├── node/ bun/ deno/ elide/
│   │   ├── schema.sql
│   │   └── run.sh
│   ├── 03-nextjs-serving/
│   │   ├── app/
│   │   ├── node/ bun/ deno/ elide/
│   │   └── run.sh
│   ├── 04-micro-benchmarks/
│   │   ├── json/ crypto/
│   │   └── run.sh
│   └── 05-polyglot-vs-native/
│       ├── elide-python/ cpython/
│       ├── elide-kotlin/ kotlin-jvm/
│       └── run.sh
├── results/                        # gitignored
├── scripts/
│   ├── run-all.sh
│   ├── setup.sh
│   └── collect-results.sh
└── docs/
```

## Prerequisites

- Ubuntu (tested on 22.04/24.04)
- Docker & Docker Compose (for PostgreSQL)
- wrk2
- Node.js (LTS), Bun, Deno, Elide
- Python 3.12+ and CPython (for polyglot benchmarks)
- Kotlin and JDK 21+ (for polyglot benchmarks)

## Quick Start

```bash
# 1. Install runtimes and tools
./scripts/setup.sh

# 2. Start PostgreSQL
docker compose up -d

# 3. Run all benchmarks
./scripts/run-all.sh

# 4. Or run individually
cd benchmarks/01-http-hello-world && ./run.sh
```

## Results

Results are written to `results/` as CSV and JSON. Each benchmark run includes:
- Timestamp and runtime versions
- System info (CPU, RAM, kernel)
- Raw wrk2 output
- Aggregated metrics

## Disclaimer

- Elide is in **beta** (1.0.0-beta10). Performance may change significantly before stable release.
- This is a personal technical evaluation, not a scientific paper. Methodology is documented but not peer-reviewed.
- Benchmarks are synthetic. Real-world performance depends on your workload.
- "Fastest" in a micro-benchmark doesn't mean "best for your project."
