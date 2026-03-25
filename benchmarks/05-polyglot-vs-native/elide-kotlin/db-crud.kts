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
