# TODO

## Phase 0: Project Setup
- [ ] Initialize git repository
- [ ] Create `.gitignore` (results/, node_modules/, .next/, etc.)
- [ ] Set up `docker-compose.yml` for PostgreSQL 16
- [ ] Create and document `postgres/postgresql.conf`
- [ ] Create `scripts/setup.sh` to install all runtimes and tools
- [ ] Install wrk2 (compile from source or package manager)
- [ ] Verify all 4 runtimes are installed and working (`node -v`, `bun -v`, `deno -v`, `elide -v`)

## Phase 1: HTTP Hello World
- [ ] Implement Node.js server (`http.createServer`, plain text response)
- [ ] Implement Bun server (`Bun.serve`)
- [ ] Implement Deno server (`Deno.serve`)
- [ ] Implement Elide server (`Elide.http`)
- [ ] Write `run.sh` — starts server, waits for ready, runs wrk2, kills server, saves results
- [ ] Decide on wrk2 parameters (threads, connections, duration, target rate)
- [ ] Run locally on WSL2 to verify everything works end-to-end
- [ ] Collect and compare initial results

## Phase 2: Database CRUD
- [ ] Write `schema.sql` (users table: id, name, email, created_at)
- [ ] Implement Node.js benchmark with `pg`
- [ ] Implement Bun benchmark with `pg` (standard driver)
- [ ] Implement Bun benchmark with `Bun.sql` (native driver)
- [ ] Implement Deno benchmark with `deno-postgres`
- [ ] Implement Elide benchmark with `elide:postgres`
- [ ] Each benchmark: INSERT N rows, SELECT by id, UPDATE by id, DELETE by id
- [ ] Write `run.sh` — starts PG container, runs schema, runs each benchmark, cleans up
- [ ] Verify DB is cleaned between runs (DROP/CREATE table or TRUNCATE)
- [ ] Run locally to verify

## Phase 3: Next.js Serving
- [ ] Scaffold vanilla Next.js app (latest version, `npx create-next-app@latest`)
- [ ] Keep it minimal — default pages, no extra libraries
- [ ] Build the app with Node (`npm run build` / `next build`)
- [ ] Figure out how to serve the `.next` output with each runtime:
  - [ ] Node: `next start` (baseline)
  - [ ] Bun: `bun run next start` or `bun --bun next start`
  - [ ] Deno: investigate if `deno run` can serve Next.js output
  - [ ] Elide: investigate Node API compatibility — may or may not work
- [ ] Document which runtimes can/cannot serve it (this IS a valid result)
- [ ] Write `run.sh` — serves app, runs wrk2 against it, collects results
- [ ] Measure TTFB, throughput, and memory

## Phase 4: Micro-benchmarks
### JSON
- [ ] Write JSON parse/stringify benchmark (1M iterations of a ~1KB object)
- [ ] Implement for Node, Bun, Deno, Elide
- [ ] Report ops/sec and total time

### Crypto
- [ ] Write SHA-256 benchmark (100K hashes of a short string)
- [ ] Write `crypto.randomUUID()` benchmark (1M calls)
- [ ] Implement for Node, Bun, Deno, Elide
- [ ] Report ops/sec and total time

- [ ] Write `run.sh` for all micro-benchmarks

## Phase 5: Polyglot vs Native
### Python
- [ ] Implement HTTP Hello World in Python on Elide
- [ ] Implement HTTP Hello World in CPython (using `http.server` or `uvicorn`)
- [ ] Implement DB CRUD in Python on Elide
- [ ] Implement DB CRUD in CPython (using `psycopg2` or `asyncpg`)
- [ ] Benchmark both with wrk2 (HTTP) and custom loop (DB)

### Kotlin
- [ ] Implement HTTP Hello World in Kotlin on Elide (`.kts` script)
- [ ] Implement HTTP Hello World in Kotlin/JVM (using `ktor` or raw `com.sun.net.httpserver`)
- [ ] Implement DB CRUD in Kotlin on Elide
- [ ] Implement DB CRUD in Kotlin/JVM (using JDBC)
- [ ] Benchmark both with wrk2 (HTTP) and custom loop (DB)

- [ ] Write `run.sh` for polyglot benchmarks

## Phase 6: Scripts & Automation
- [ ] Write `scripts/run-all.sh` — runs all benchmarks in sequence
- [ ] Write `scripts/collect-results.sh` — aggregates all results into summary CSV/JSON
- [ ] Add system info collection (CPU, RAM, kernel, runtime versions) to results
- [ ] Add timestamp to each run

## Phase 7: Run on Ubuntu Server
- [ ] Set up Ubuntu server environment
- [ ] Clone repo, run `scripts/setup.sh`
- [ ] Run full suite with `scripts/run-all.sh`
- [ ] Verify results look reasonable (no obvious WSL2 vs bare metal anomalies)
- [ ] Run the suite 3 times, check consistency between runs

## Phase 8: Analysis & Documentation
- [ ] Compare results across runtimes per benchmark category
- [ ] Note any runtimes that failed or couldn't complete a benchmark (this is useful data)
- [ ] Document surprising results
- [ ] Update README with findings summary
- [ ] Check if Elide's 800K RPS claim holds up in our environment

---

## Open Questions
- [ ] Does Elide actually support serving a Next.js build? Need to test — if not, document it as a finding
- [ ] What Python HTTP framework does Elide support? Need to check if `Elide.http` is available from Python or if there's a Python-specific API
- [ ] What Kotlin HTTP API does Elide expose? Check if `.kts` scripts can use `Elide.http` or need ktor
- [ ] Does `deno run` work with Next.js output? May need `deno compile` or a compatibility layer
- [ ] Should we also test cold start time? (Quick to add, valuable metric)
- [ ] wrk2 parameters: what target rate to start with? Need to find saturation point first per runtime
