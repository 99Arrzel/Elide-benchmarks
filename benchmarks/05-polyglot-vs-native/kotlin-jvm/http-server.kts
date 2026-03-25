// Minimal HTTP server using com.sun.net.httpserver (JDK built-in)
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress

val port = System.getenv("PORT")?.toInt() ?: 3000
val server = HttpServer.create(InetSocketAddress(port), 0)

server.createContext("/") { exchange ->
    val response = "Hello, World!"
    exchange.sendResponseHeaders(200, response.length.toLong())
    exchange.responseBody.use { it.write(response.toByteArray()) }
}

println("Kotlin/JVM listening on port $port")
server.start()
