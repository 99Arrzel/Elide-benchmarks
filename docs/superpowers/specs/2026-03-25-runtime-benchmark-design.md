# Runtime Benchmark Design: Elide vs Node vs Bun vs Deno

**Date:** 2026-03-25
**Goal:** Personal technical evaluation comparing JS/TS runtimes with a focus on Elide's claims
**Audience:** Author (personal evaluation), may be shared informally

---

## Runtimes Under Test

| Runtime | Version Strategy | Notes |
|---------|-----------------|-------|
| **Node.js** | Latest LTS | Baseline, most mature |
| **Bun** | Latest stable | V8 alternative (JSC), native APIs |
| **Deno** | Latest stable | V8-based, security-first |
| **Elide** | Latest beta (1.0.0-beta10+) | GraalVM-based, polyglot |

---

## Benchmark Categories

### 1. HTTP Hello World
- Minimal HTTP server returning `"Hello, World!"` plain text
- Each runtime uses its idiomatic built-in HTTP API (no frameworks)
- Load tested with **wrk2** at fixed request rates
- **Measures:** req/s, latency p50/p95/p99, error rate, RSS memory

### 2. DB CRUD (PostgreSQL)
- PostgreSQL 16 in Docker container with committed `postgresql.conf`
- Operations: INSERT, SELECT, UPDATE, DELETE on a simple `users` table
- Each runtime uses its "standard" driver + native driver where available:
  - Node: `pg`
  - Bun: `pg` + `Bun.sql`
  - Deno: `deno-postgres`
  - Elide: built-in `elide:postgres`
- **Measures:** ops/sec per operation type, latency, memory

### 3. Next.js Serving
- Pre-built Next.js app (latest version, no extra libraries)
- Build once with Node, then serve the output with all 4 runtimes
- **Measures:** req/s, latency p50/p95/p99, TTFB, memory

### 4. Micro-benchmarks
- **JSON:** `JSON.parse()` and `JSON.stringify()` throughput (1M iterations)
- **Crypto:** SHA-256 hashing, `crypto.randomUUID()` throughput
- **Measures:** ops/sec per operation

### 5. Polyglot vs Native
- Same HTTP Hello World + DB CRUD benchmarks implemented in:
  - Python on Elide vs CPython
  - Kotlin on Elide vs Kotlin/JVM
- **Measures:** same metrics as categories 1 and 2

---

## Methodology

### Load Testing (HTTP benchmarks)
- Tool: **wrk2** (constant-throughput, avoids coordinated omission)
- Protocol: 10s warmup → 30s measurement window
- 3 runs per configuration, report median
- Find saturation point first, then test at 50%, 75%, 90% of max throughput
- Collect latency distribution (p50, p95, p99)

### DB Benchmarks
- Custom script per runtime that runs N operations in a loop
- Warmup phase (1000 ops), then measurement phase (10,000+ ops)
- 3 runs per configuration, report median
- Single connection (no pooling) for fair comparison

### Memory
- RSS measured via `ps -o rss` at idle and under load

### Environment
- Develop/debug locally on WSL2
- Run real benchmarks on dedicated Ubuntu server
- PostgreSQL: Docker container (`postgres:16`) with pinned `postgresql.conf`
- Runtimes: installed bare metal (not in Docker)
- Each benchmark run in isolation (one runtime at a time, clean state)

---

## Project Structure

```
elide-comparisons/
├── README.md
├── TODO.md
├── docker-compose.yml              # PostgreSQL only
├── postgres/
│   └── postgresql.conf             # Committed, documented config
├── benchmarks/
│   ├── 01-http-hello-world/
│   │   ├── node/
│   │   │   └── server.ts
│   │   ├── bun/
│   │   │   └── server.ts
│   │   ├── deno/
│   │   │   └── server.ts
│   │   ├── elide/
│   │   │   └── server.ts
│   │   └── run.sh
│   ├── 02-db-crud/
│   │   ├── node/
│   │   │   └── bench.ts
│   │   ├── bun/
│   │   │   ├── bench-pg.ts         # standard driver
│   │   │   └── bench-native.ts     # Bun.sql
│   │   ├── deno/
│   │   │   └── bench.ts
│   │   ├── elide/
│   │   │   └── bench.ts
│   │   ├── schema.sql
│   │   └── run.sh
│   ├── 03-nextjs-serving/
│   │   ├── app/                    # shared Next.js project
│   │   ├── node/
│   │   ├── bun/
│   │   ├── deno/
│   │   ├── elide/
│   │   └── run.sh
│   ├── 04-micro-benchmarks/
│   │   ├── json/
│   │   │   ├── node.ts
│   │   │   ├── bun.ts
│   │   │   ├── deno.ts
│   │   │   └── elide.ts
│   │   ├── crypto/
│   │   │   ├── node.ts
│   │   │   ├── bun.ts
│   │   │   ├── deno.ts
│   │   │   └── elide.ts
│   │   └── run.sh
│   └── 05-polyglot-vs-native/
│       ├── elide-python/
│       │   ├── http-server.py
│       │   └── db-crud.py
│       ├── cpython/
│       │   ├── http-server.py
│       │   └── db-crud.py
│       ├── elide-kotlin/
│       │   ├── http-server.kts
│       │   └── db-crud.kts
│       ├── kotlin-jvm/
│       │   ├── http-server.kts
│       │   └── db-crud.kts
│       └── run.sh
├── results/                        # gitignored, generated output
│   └── .gitkeep
├── scripts/
│   ├── run-all.sh                  # orchestrator
│   ├── setup.sh                    # install runtimes + tools
│   └── collect-results.sh          # aggregate CSV/JSON
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-03-25-runtime-benchmark-design.md
```

---

## Decisions Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| PostgreSQL setup | Docker container, runtimes bare metal | Isolates DB cleanly, negligible overhead for client-side benchmarks |
| Load tester | wrk2 | Constant-throughput, used by TechEmpower, avoids coordinated omission |
| Next.js approach | Pre-build once, serve with all runtimes | Tests runtime serving perf, not Next.js build (which uses SWC/Turbopack internally) |
| PG drivers | Standard + native where available | Fair comparison AND "best each runtime can do" |
| Runs per benchmark | 3, report median | Balances time vs statistical noise |
| Develop locally, benchmark on server | WSL2 for dev, Ubuntu server for real runs | WSL2 adds virtualization overhead |
