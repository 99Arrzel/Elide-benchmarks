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
