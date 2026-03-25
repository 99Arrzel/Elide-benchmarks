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
