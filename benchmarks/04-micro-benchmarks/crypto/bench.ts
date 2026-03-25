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
