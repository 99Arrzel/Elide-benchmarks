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
