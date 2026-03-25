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
