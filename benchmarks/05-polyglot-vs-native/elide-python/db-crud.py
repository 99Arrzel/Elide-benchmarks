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
