import ArgumentParser
import Foundation

@main
struct ATL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "atl",
        abstract: "ATL - Agent Touch Layer CLI",
        version: "0.2.0",
        subcommands: [
            Goto.self,
            Click.self,
            Type.self,
            Snapshot.self,
            Mark.self,
            Screenshot.self,
            PDF.self,
            Wait.self,
            State.self,
            Ping.self,
            Debug.self,
            Reset.self,
            Reload.self,
            Back.self,
        ],
        defaultSubcommand: Ping.self
    )
}

// Debug command to trace issues
struct Debug: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Debug connection and raw API calls")
    
    @Argument(help: "Method to call")
    var method: String = "ping"
    
    @Option(name: .long, help: "JSON params (e.g. '{\"url\":\"https://example.com\"}')")
    var params: String = "{}"
    
    @Option(name: .long, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        print("=== ATL Debug ===")
        print("Port: \(port)")
        print("Method: \(method)")
        print("Params: \(params)")
        print()
        
        // Parse params
        guard let paramsData = params.data(using: .utf8),
              let paramsDict = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] else {
            print("ERROR: Invalid JSON params")
            throw ExitCode.failure
        }
        
        let client = ATLClient(port: port)
        do {
            let result = try client.call(method, params: paramsDict, verbose: true)
            print()
            print("=== Result ===")
            if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                print(jsonStr)
            } else {
                print(result)
            }
        } catch {
            print()
            print("=== Error ===")
            if let atlError = error as? ATLError {
                print(atlError.jsonOutput)
            } else {
                print("Error: \(error.localizedDescription)")
            }
            throw ExitCode.failure
        }
    }
}

// MARK: - Global Options

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output errors as JSON for agent consumption")
    var json: Bool = false
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
}

// MARK: - API Client

struct ATLClient {
    let host: String
    let port: Int
    let jsonOutput: Bool
    
    init(host: String = "localhost", port: Int = 9222, jsonOutput: Bool = false) {
        self.host = host
        self.port = port
        self.jsonOutput = jsonOutput
    }
    
    func call(_ method: String, params: [String: Any] = [:], verbose: Bool = false) throws -> [String: Any] {
        let url = URL(string: "http://localhost:\(port)/command")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        
        let command: [String: Any] = [
            "id": "cli-\(Int(Date().timeIntervalSince1970))",
            "method": method,
            "params": params
        ]
        
        let bodyData = try JSONSerialization.data(withJSONObject: command, options: [])
        request.httpBody = bodyData
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        
        if verbose {
            fputs("[DEBUG] URL: \(url)\n", stderr)
            fputs("[DEBUG] Body: \(String(data: bodyData, encoding: .utf8) ?? "nil")\n", stderr)
            fputs("[DEBUG] Body length: \(bodyData.count)\n", stderr)
            fputs("[DEBUG] Headers: \(request.allHTTPHeaderFields ?? [:])\n", stderr)
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        var error: Error?
        
        // Use ephemeral session to avoid any caching/cookie issues
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        
        let task = session.dataTask(with: request) { data, response, err in
            defer { semaphore.signal() }
            
            if let err = err {
                error = ATLError.connectionFailed(err.localizedDescription)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if verbose {
                    fputs("[DEBUG] HTTP Status: \(httpResponse.statusCode)\n", stderr)
                }
                if httpResponse.statusCode != 200 {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                    error = ATLError.serverError(httpResponse.statusCode, body)
                    return
                }
            }
            
            guard let data = data else {
                error = ATLError.noData
                return
            }
            
            if verbose {
                fputs("[DEBUG] Response: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")\n", stderr)
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result = json
                } else {
                    error = ATLError.parseError("Response is not a JSON object")
                }
            } catch let e {
                error = ATLError.parseError(e.localizedDescription)
            }
        }
        
        task.resume()
        semaphore.wait()
        
        if let error = error {
            throw error
        }
        
        guard let result = result else {
            throw ATLError.noData
        }
        
        if let success = result["success"] as? Bool, !success {
            let msg = result["error"] as? String ?? "Unknown error"
            throw ATLError.apiError(msg)
        }
        
        return result["result"] as? [String: Any] ?? [:]
    }
}

enum ATLError: Error, LocalizedError {
    case noData
    case connectionFailed(String)
    case serverError(Int, String)
    case apiError(String)
    case parseError(String)
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .noData: 
            return "No data received from server. Is ATL running? Try: atl ping"
        case .connectionFailed(let msg): 
            return "Connection failed: \(msg). Check if ATL server is running on the correct port."
        case .serverError(let code, let msg): 
            return "Server error (\(code)): \(msg)"
        case .apiError(let msg): 
            return "API error: \(msg)"
        case .parseError(let msg): 
            return "Failed to parse response: \(msg)"
        case .timeout: 
            return "Request timed out. The page might still be loading."
        }
    }
    
    var jsonOutput: String {
        let dict: [String: Any] = [
            "success": false,
            "error": errorDescription ?? "Unknown error",
            "errorType": String(describing: self).components(separatedBy: "(").first ?? "unknown",
            "recoverable": isRecoverable,
            "suggestion": recoverySuggestion
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"Failed to serialize error\"}"
    }
    
    var isRecoverable: Bool {
        switch self {
        case .timeout, .apiError: return true
        case .noData, .connectionFailed: return false
        case .serverError(let code, _): return code >= 500
        case .parseError: return false
        }
    }
    
    var recoverySuggestion: String {
        switch self {
        case .noData, .connectionFailed:
            return "Start ATL server: open AtlBrowser app in iOS Simulator"
        case .serverError(let code, _) where code >= 500:
            return "Retry the command"
        case .apiError(let msg) where msg.contains("not found"):
            return "Element not found. Try: atl snapshot to see available elements"
        case .apiError:
            return "Check command parameters"
        case .parseError:
            return "This may be a bug in ATL. Report the full error output."
        case .timeout:
            return "Use 'atl wait' before retrying, or increase timeout"
        default:
            return "See ATL documentation"
        }
    }
}

// MARK: - Commands

struct Ping: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check if ATL server is running")
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        let url = URL(string: "http://localhost:\(port)/ping")!
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "ok" {
                success = true
            }
        }
        task.resume()
        semaphore.wait()
        
        if success {
            print("✓ ATL server running on port \(port)")
        } else {
            print("✗ ATL server not responding on port \(port)")
            throw ExitCode.failure
        }
    }
}

struct Goto: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Navigate to a URL")
    
    @Argument(help: "URL to navigate to")
    var url: String
    
    @OptionGroup var options: GlobalOptions
    
    @Flag(name: .shortAndLong, help: "Wait for DOM stable after navigation")
    var wait: Bool = false
    
    func run() throws {
        let client = ATLClient(port: options.port, jsonOutput: options.json)
        
        do {
            let result = try client.call("goto", params: ["url": url])
            
            if wait {
                let waitResult = try client.call("waitForDOMStable", params: ["stabilityMs": 1500, "timeoutMs": 15000])
                let stable = waitResult["stable"] as? Bool ?? false
                if options.json {
                    print(encodeJSON(["success": true, "url": result["url"], "stable": stable]))
                } else {
                    print("→ \(result["url"] ?? url)")
                    print(stable ? "✓ DOM stable" : "⚠ Timeout waiting for DOM")
                }
            } else {
                if options.json {
                    print(encodeJSON(["success": true, "url": result["url"]]))
                } else {
                    print("→ \(result["url"] ?? url)")
                }
            }
        } catch {
            outputError(error, json: options.json)
            throw ExitCode.failure
        }
    }
}

// Helper to output errors in JSON or human format
func outputError(_ error: Error, json: Bool) {
    if json {
        if let atlError = error as? ATLError {
            fputs(atlError.jsonOutput + "\n", stderr)
        } else {
            let dict: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
                "errorType": "unknown",
                "recoverable": false,
                "suggestion": "Check the error message for details"
            ]
            fputs(encodeJSON(dict) + "\n", stderr)
        }
    } else {
        fputs("Error: \(error.localizedDescription)\n", stderr)
    }
}

func encodeJSON(_ dict: [String: Any?]) -> String {
    let cleanDict = dict.compactMapValues { $0 }
    if let data = try? JSONSerialization.data(withJSONObject: cleanDict, options: []),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    return "{}"
}

struct Click: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Click an element by text or label")
    
    @Argument(help: "Text to find and click, or label number if --label is set")
    var target: String
    
    @Flag(name: .shortAndLong, help: "Target is a label number from marks")
    var label: Bool = false
    
    @Flag(name: .shortAndLong, help: "Exact text match")
    var exact: Bool = false
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        let client = ATLClient(port: port)
        
        if label {
            guard let labelNum = Int(target) else {
                throw ValidationError("Label must be a number")
            }
            let result = try client.call("clickMark", params: ["label": labelNum])
            print("✓ Clicked label \(result["clicked"] ?? labelNum)")
        } else {
            let result = try client.call("clickText", params: ["text": target, "exact": exact])
            let tag = result["tag"] as? String ?? "?"
            let text = result["text"] as? String ?? target
            print("✓ Clicked <\(tag)> \"\(text.prefix(50))\"")
        }
    }
}

struct Type: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Type text into focused element")
    
    @Argument(help: "Text to type")
    var text: String
    
    @Flag(name: .shortAndLong, help: "Press Enter after typing")
    var enter: Bool = false
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        let client = ATLClient(port: port)
        _ = try client.call("type", params: ["text": text])
        print("⌨ Typed: \"\(text.prefix(50))\"")
        
        if enter {
            _ = try client.call("press", params: ["key": "Enter"])
            print("⏎ Enter")
        }
    }
}

struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get page state (marks + text + optional PDF)")
    
    @Flag(name: .long, help: "Include full page PDF")
    var pdf: Bool = false
    
    @Option(name: .shortAndLong, help: "Save PDF to file")
    var output: String?
    
    @Flag(name: .shortAndLong, help: "Show full marks (not truncated)")
    var full: Bool = false
    
    @OptionGroup var options: GlobalOptions
    
    func run() throws {
        let client = ATLClient(port: options.port, jsonOutput: options.json)
        
        do {
            let includePdf = pdf || output != nil
            let result = try client.call("agentSnapshot", params: ["pdf": includePdf])
            
            // Save PDF if output path specified
            if let output = output, let pdfData = result["pdf"] as? String {
                if let data = Data(base64Encoded: pdfData) {
                    try data.write(to: URL(fileURLWithPath: output))
                }
            }
            
            if options.json {
                // JSON output - include everything an agent needs
                var jsonResult: [String: Any] = [
                    "success": true,
                    "url": result["url"] ?? "",
                    "title": result["title"] ?? "",
                    "markCount": result["markCount"] ?? 0,
                    "marks": result["marks"] ?? "",
                    "text": result["text"] ?? ""
                ]
                if let output = output {
                    jsonResult["pdfSaved"] = output
                }
                print(encodeJSON(jsonResult))
            } else {
                // Human-readable output
                print("URL: \(result["url"] ?? "?")")
                print("Title: \(result["title"] ?? "?")")
                print("Marks: \(result["markCount"] ?? 0)")
                print()
                
                if let marks = result["marks"] as? String {
                    let lines = marks.split(separator: "\n")
                    if full {
                        print(marks)
                    } else {
                        for line in lines.prefix(20) {
                            print(line)
                        }
                        if lines.count > 20 {
                            print("... (\(lines.count - 20) more, use --full to see all)")
                        }
                    }
                }
                
                if let output = output {
                    print("\n✓ PDF saved: \(output)")
                }
            }
        } catch {
            outputError(error, json: options.json)
            throw ExitCode.failure
        }
    }
}

struct Mark: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mark interactive elements on page")
    
    @Flag(name: .shortAndLong, help: "Compact output (just label:text)")
    var compact: Bool = false
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        let client = ATLClient(port: port)
        
        if compact {
            let result = try client.call("markCompact", params: [:])
            print(result["marks"] ?? "")
            print("\n\(result["count"] ?? 0) elements")
        } else {
            let result = try client.call("markAll", params: [:])
            if let elements = result["elements"] as? [[String: Any]] {
                for el in elements.prefix(30) {
                    let label = el["label"] ?? "?"
                    let text = (el["text"] as? String)?.prefix(50) ?? ""
                    let tag = el["tagName"] ?? "?"
                    print("[\(label)] \(text) <\(tag)>")
                }
                if elements.count > 30 {
                    print("... (\(elements.count - 30) more)")
                }
            }
            print("\n\(result["count"] ?? 0) elements marked")
        }
    }
}

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Take a screenshot (PNG)")
    
    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "screenshot.png"
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        let client = ATLClient(port: port)
        
        // First unmark elements for clean screenshot
        _ = try? client.call("unmarkElements", params: [:])
        
        let result = try client.call("screenshot", params: [:])
        
        if let dataStr = result["data"] as? String,
           let data = Data(base64Encoded: dataStr) {
            try data.write(to: URL(fileURLWithPath: output))
            print("✓ Screenshot saved: \(output) (\(data.count) bytes)")
        }
    }
}

struct PDF: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Capture full page as PDF")
    
    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "page.pdf"
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        let client = ATLClient(port: port)
        
        // First unmark elements for clean capture
        _ = try? client.call("unmarkElements", params: [:])
        
        let result = try client.call("screenshot", params: ["fullPage": true])
        
        if let dataStr = result["data"] as? String,
           let data = Data(base64Encoded: dataStr) {
            try data.write(to: URL(fileURLWithPath: output))
            print("✓ PDF saved: \(output) (\(data.count) bytes)")
        }
    }
}

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wait for DOM to stabilize or for specific content")
    
    @Argument(help: "Stability time in ms (default: 500)")
    var ms: Int = 500  // Lowered from 1000 per Playwright guidance
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    @Option(name: .long, help: "Maximum time to wait (ms)")
    var timeout: Int = 10000
    
    @Option(name: .long, help: "Wait for text to appear on page")
    var forText: String?
    
    @Option(name: .long, help: "Wait for text to disappear from page")
    var untilGone: String?
    
    @Option(name: .long, help: "Wait for CSS selector to appear")
    var forSelector: String?
    
    @Option(name: .long, help: "Wait for network requests to settle (quiet time in ms)")
    var network: Int?
    
    func run() throws {
        let client = ATLClient(port: port)
        
        // Wait for specific CSS selector to appear (most reliable for SPAs)
        if let selector = forSelector {
            do {
                // Server throws on timeout, returns empty on success
                _ = try client.call("waitForSelector", params: [
                    "selector": selector,
                    "timeout": Double(timeout) / 1000.0  // Convert ms to seconds
                ])
                print("✓ Found: \(selector)")
            } catch {
                print("✗ Timeout waiting for: \(selector)")
                throw ExitCode.failure
            }
            return
        }
        
        // Wait for specific text to appear
        if let text = forText {
            let startTime = Date()
            while Date().timeIntervalSince(startTime) * 1000 < Double(timeout) {
                let result = try client.call("agentSnapshot", params: ["pdf": false])
                if let pageText = result["text"] as? String,
                   pageText.localizedCaseInsensitiveContains(text) {
                    print("✓ Found: \"\(text)\"")
                    return
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            print("✗ Timeout waiting for: \"\(text)\"")
            throw ExitCode.failure
        }
        
        // Wait for text to disappear
        if let text = untilGone {
            let startTime = Date()
            while Date().timeIntervalSince(startTime) * 1000 < Double(timeout) {
                let result = try client.call("agentSnapshot", params: ["pdf": false])
                if let pageText = result["text"] as? String,
                   !pageText.localizedCaseInsensitiveContains(text) {
                    print("✓ Gone: \"\(text)\"")
                    return
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            print("✗ Timeout waiting for \"\(text)\" to disappear")
            throw ExitCode.failure
        }
        
        // Wait for network to settle
        if let networkMs = network {
            let result = try client.call("waitForNetworkIdle", params: ["quietMs": networkMs, "timeoutMs": timeout])
            let idle = result["idle"] as? Bool ?? false
            print(idle ? "✓ Network idle" : "⚠ Network still active")
            if !idle { throw ExitCode.failure }
            return
        }
        
        // Default: wait for DOM stability
        let result = try client.call("waitForDOMStable", params: ["stabilityMs": ms, "timeoutMs": timeout])
        let stable = result["stable"] as? Bool ?? false
        print(stable ? "✓ DOM stable" : "⚠ Timeout waiting for DOM")
        if !stable { throw ExitCode.failure }
    }
}

struct State: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get ATL tracking state")
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    func run() throws {
        let client = ATLClient(port: port)
        let result = try client.call("getATLState", params: [:])
        
        print("Ready: \(result["ready"] ?? false)")
        print("Mutations: \(result["mutationCount"] ?? 0)")
        print("Network requests: \(result["networkCount"] ?? 0)")
        print("Errors: \(result["errorCount"] ?? 0)")
    }
}

// MARK: - Navigation Commands

struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reset browser to blank page (about:blank)")
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    @Flag(name: .long, help: "Clear cookies")
    var clearCookies: Bool = false
    
    @Option(name: .long, help: "URL to reset to (default: about:blank)")
    var url: String = "about:blank"
    
    func run() throws {
        let client = ATLClient(port: port)
        
        if clearCookies {
            _ = try? client.call("deleteCookies", params: [:])
            print("✓ Cleared cookies")
        }
        
        // Navigate to target URL
        _ = try client.call("goto", params: ["url": url])
        
        // Clear ATL state
        _ = try client.call("clearATLState", params: [:])
        
        if url == "about:blank" {
            print("✓ Browser reset to blank page")
        } else {
            print("✓ Browser reset to: \(url)")
        }
    }
}

struct Reload: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reload current page")
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    @Flag(name: .long, help: "Hard reload (bypass cache)")
    var hard: Bool = false
    
    @Flag(name: .shortAndLong, help: "Wait for DOM stable after reload")
    var wait: Bool = false
    
    func run() throws {
        let client = ATLClient(port: port)
        
        _ = try client.call("reload", params: ["bypassCache": hard])
        print("↻ Page reloaded\(hard ? " (cache bypassed)" : "")")
        
        if wait {
            // Wait for page to stabilize
            let result = try client.call("waitForDOMStable", params: ["stabilityMs": 1500, "timeoutMs": 10000])
            let stable = result["stable"] as? Bool ?? false
            print(stable ? "✓ DOM stable" : "⚠ Timeout waiting for DOM")
        }
    }
}

struct Back: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Go back in browser history")
    
    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222
    
    @Flag(name: .shortAndLong, help: "Wait for DOM stable after navigation")
    var wait: Bool = false
    
    func run() throws {
        let client = ATLClient(port: port)
        
        _ = try client.call("goBack", params: [:])
        print("← Back")
        
        if wait {
            let result = try client.call("waitForDOMStable", params: ["stabilityMs": 1000, "timeoutMs": 8000])
            let stable = result["stable"] as? Bool ?? false
            print(stable ? "✓ DOM stable" : "⚠ Timeout waiting for DOM")
        }
    }
}
