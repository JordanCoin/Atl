# ATL CLI Known Issues

## ~~HTTP 400 "Invalid command" errors~~ (RESOLVED)

**Fixed** by replacing NWListener with FlyingFox HTTP server. The root cause was NWListener's
single `connection.receive()` call assuming the full HTTP body arrived in one TCP packet.
URLSession's connection reuse / chunked encoding split the body across packets, causing
truncated JSON and decode failures. FlyingFox handles HTTP framing properly.
