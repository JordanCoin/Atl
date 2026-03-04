# ATL CLI Known Issues

## HTTP 400 "Invalid command" errors (intermittent)

### Symptom
The CLI intermittently receives HTTP 400 responses with `{"error":"Invalid command"}` even when sending valid JSON.

### Observed behavior
- `curl` with identical JSON always works
- First few CLI requests after server restart work
- Subsequent requests fail with 400
- The server's `JSONDecoder().decode(Command.self, from: body)` is failing

### Suspected cause
Something about how Swift URLSession interacts with NWListener-based HTTP server:
- Possibly connection reuse/keep-alive issues
- Possibly chunk encoding differences
- Possibly IPv6 vs IPv4 differences

### Workarounds tried (none fixed)
- Explicit Content-Length header
- charset=utf-8 in Content-Type
- Connection: close header
- URLSessionConfiguration.ephemeral
- 127.0.0.1 vs localhost

### To investigate
1. Add detailed logging to NWListener's `receiveRequest` to see raw bytes
2. Check if body is being split across multiple receive calls
3. Test with a standard HTTP server (not NWListener) 
4. Consider using `Process` to shell out to `curl` as workaround

### Temporary workaround
Restart the ATL app in simulator if CLI stops working.
