// HTTP server running on Elide's Kotlin runtime
// NOTE: Elide runs .kts scripts natively. May need Elide-specific HTTP API.
// Attempting JDK built-in first; adjust if Elide exposes its own API.

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress

val port = System.getenv("PORT")?.toInt() ?: 3000
val server = HttpServer.create(InetSocketAddress(port), 0)

server.createContext("/") { exchange ->
    val response = "Hello, World!"
    exchange.sendResponseHeaders(200, response.length.toLong())
    exchange.responseBody.use { it.write(response.toByteArray()) }
}

println("Elide Kotlin listening on port $port")
server.start()
