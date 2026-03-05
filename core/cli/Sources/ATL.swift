import ArgumentParser
import Foundation
import CryptoKit
#if canImport(PDFKit)
import PDFKit
#endif

@main
struct ATL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "atl",
        abstract: "ATL - Agent Touch Layer CLI",
        version: "0.3.0",
        subcommands: [
            Goto.self,
            Click.self,
            Unmark.self,
            PDFText.self,
            PDF.self,
            Wait.self,
            State.self,
            Ping.self,
            Debug.self,
            Reset.self,
            Reload.self,
            Back.self,
            Dataset.self,
            Classify.self,
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
            return "Element not found. Try: atl pdftext --mark to see available elements"
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
    static let configuration = CommandConfiguration(abstract: "Click a marked element by label number")

    @Option(name: .shortAndLong, help: "Label number from marks")
    var label: Int

    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222

    func run() throws {
        let client = ATLClient(port: port)
        let result = try client.call("clickMark", params: ["label": label])
        print("✓ Clicked label \(result["clicked"] ?? label)")
    }
}

struct Unmark: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove all marks from the page")

    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222

    func run() throws {
        let client = ATLClient(port: port)
        _ = try client.call("unmarkElements", params: [:])
        print("✓ Marks cleared")
    }
}

struct PDFText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdftext",
        abstract: "Extract text from the page's PDF text layer (native Apple extraction)"
    )

    @Flag(name: .shortAndLong, help: "Mark elements before extracting (mark → pdftext in one call)")
    var mark: Bool = false

    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222

    func run() throws {
        let client = ATLClient(port: port)
        if mark {
            _ = try client.call("markAll", params: [:])
        }
        let result = try client.call("pdfText", params: [:])
        print(result["text"] ?? "")
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
    var ms: Int = 500

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
                _ = try client.call("waitForSelector", params: [
                    "selector": selector,
                    "timeout": Double(timeout) / 1000.0
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

        _ = try client.call("goto", params: ["url": url])
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

// MARK: - Page Classifier

struct Classify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Classify the current page type (cart, product, error, etc.)")

    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 9222

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    /// Page type rules. Each rule has:
    /// - required: ALL must match
    /// - boost: each match adds to score
    /// - reject: any match disqualifies
    /// - minScore: minimum total score to qualify (required=3pts each, boost=2pts each)
    private static let rules: [(type: String, required: [String], boost: [String], reject: [String], minScore: Int)] = [
        (
            type: "error",
            required: ["something went wrong"],
            boost: ["oops", "refresh", "try again", "error"],
            reject: [],
            minScore: 3
        ),
        (
            type: "empty_cart",
            required: ["cart is empty"],
            boost: ["no items", "0 items", "start shopping", "your cart", "empty"],
            reject: ["subtotal", "checkout"],
            minScore: 3
        ),
        (
            type: "cart",
            required: ["subtotal"],
            boost: ["cart", "checkout", "proceed to checkout", "quantity", "remove", "total", "order summary", "estimated total", "shipping"],
            reject: [],
            minScore: 5
        ),
        (
            type: "product",
            required: ["add to cart"],
            boost: ["buy now", "in stock", "reviews", "description", "ships from", "sold by", "quantity", "price"],
            reject: ["subtotal", "proceed to checkout"],
            minScore: 5
        ),
        (
            type: "login",
            required: ["sign in"],
            boost: ["password", "email address", "create account", "forgot", "log in", "username"],
            reject: ["subtotal", "add to cart", "shop by", "deals", "browse"],
            minScore: 7  // High bar — "sign in" alone (3pts) isn't enough
        ),
        (
            type: "category",
            required: [],
            boost: ["results", "filter", "sort by", "showing", "department", "brand", "price range"],
            reject: ["add to cart", "subtotal"],
            minScore: 6
        ),
        (
            type: "search",
            required: [],
            boost: ["results for", "search results", "showing results", "no results"],
            reject: ["subtotal"],
            minScore: 4
        ),
        (
            type: "homepage",
            required: [],
            boost: ["shop by", "deals", "trending", "popular", "categories", "browse", "top sellers", "best sellers", "new arrivals", "shop now", "subscribe & save", "inspired by", "top of page", "join prime", "related to"],
            reject: ["subtotal", "proceed to checkout"],
            minScore: 6
        ),
    ]

    func run() throws {
        let client = ATLClient(port: port)
        let result = try client.call("pdfText", params: [:])
        let text = (result["text"] as? String ?? "").lowercased()

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if json {
                print(encodeJSON(["type": "blank", "confidence": "high", "signals": "no text content"]))
            } else {
                print("blank — no text content")
            }
            return
        }

        var bestType = "other"
        var bestScore = 0
        var bestSignals: [String] = []

        for rule in Self.rules {
            // Check required terms — all must be present
            let hasRequired = rule.required.allSatisfy { text.contains($0) }
            guard hasRequired else { continue }

            // Check reject terms — any present disqualifies
            let hasReject = rule.reject.contains { text.contains($0) }
            if hasReject { continue }

            // Score: required=3pts each, boost=2pts each
            var score = rule.required.count * 3
            var signals = rule.required

            for term in rule.boost {
                if text.contains(term) {
                    score += 2
                    signals.append(term)
                }
            }

            // Must meet minimum score threshold
            guard score >= rule.minScore else { continue }

            if score > bestScore {
                bestScore = score
                bestType = rule.type
                bestSignals = signals
            }
        }

        let confidence = bestScore >= 8 ? "high" : bestScore >= 5 ? "medium" : "low"

        if json {
            print(encodeJSON([
                "type": bestType,
                "confidence": confidence,
                "signals": bestSignals.joined(separator: ", ")
            ]))
        } else {
            print("\(bestType) (\(confidence)) — \(bestSignals.joined(separator: ", "))")
        }
    }
}

// MARK: - Ground Truth Schema

struct CartGroundTruth: Codable {
    let merchant: String
    let items: [CartItem]
    let total: String
    var subtotal: String?
    var tax: String?
    var shipping: String?
    var currency: String?
    var url: String?
    var timestamp: String?
    var discounts: [Discount]?
    var notes: String?

    struct CartItem: Codable {
        let name: String
        let quantity: Int
        let unit_price: String
        let total_price: String
    }

    struct Discount: Codable {
        let name: String
        let amount: String
    }

    /// Validate business rules beyond what Codable checks
    func validate() throws {
        if merchant.trimmingCharacters(in: .whitespaces).isEmpty {
            throw GTError.invalid("\"merchant\" cannot be empty")
        }
        if items.isEmpty {
            throw GTError.invalid("\"items\" must contain at least 1 item")
        }
        for (i, item) in items.enumerated() {
            var missing: [String] = []
            if item.name.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("name") }
            if item.unit_price.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("unit_price") }
            if item.total_price.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("total_price") }
            if !missing.isEmpty {
                throw GTError.invalid("Item \(i + 1) has empty required fields: \(missing.joined(separator: ", "))")
            }
            if item.quantity < 1 {
                throw GTError.invalid("Item \(i + 1) quantity must be >= 1, got \(item.quantity)")
            }
        }
        if total.trimmingCharacters(in: .whitespaces).isEmpty {
            throw GTError.invalid("\"total\" cannot be empty")
        }
    }
}

enum GTError: Error, LocalizedError {
    case invalid(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let msg): return msg
        case .decodingFailed(let msg): return msg
        }
    }
}

/// Decode ground truth JSON with clear error messages
func decodeGroundTruth(_ jsonString: String) throws -> CartGroundTruth {
    guard let data = jsonString.data(using: .utf8) else {
        throw GTError.decodingFailed("Invalid UTF-8 in ground truth JSON")
    }

    let decoder = JSONDecoder()
    do {
        let gt = try decoder.decode(CartGroundTruth.self, from: data)
        try gt.validate()
        return gt
    } catch let error as DecodingError {
        // Convert Swift's DecodingError into human-readable messages
        switch error {
        case .keyNotFound(let key, _):
            throw GTError.decodingFailed("Missing required field \"\(key.stringValue)\"")
        case .typeMismatch(let type, let ctx):
            let field = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw GTError.decodingFailed("Wrong type for \"\(field)\": expected \(type)")
        case .valueNotFound(_, let ctx):
            let field = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw GTError.decodingFailed("Null value for required field \"\(field)\"")
        case .dataCorrupted(let ctx):
            throw GTError.decodingFailed("Corrupted data: \(ctx.debugDescription)")
        @unknown default:
            throw GTError.decodingFailed("Decoding error: \(error.localizedDescription)")
        }
    } catch let error as GTError {
        throw error
    }
}

// MARK: - Dataset Commands

struct Dataset: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage training dataset (Donut gt_parse format)",
        subcommands: [
            Append.self,
            Validate.self,
            List.self,
            Schema.self,
        ]
    )

    static func datasetDir(override: String?) -> URL {
        if let override = override {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atl")
            .appendingPathComponent("dataset")
    }

    struct Append: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Append a PDF with ground truth to the dataset")

        @Option(name: .long, help: "Path to the PDF file")
        var pdf: String

        @Option(name: .long, help: "Ground truth JSON (merchant, items, total, etc.)")
        var groundTruth: String

        @Option(name: .long, help: "Dataset directory (default: ~/.atl/dataset)")
        var dir: String?

        func run() throws {
            let pdfURL = URL(fileURLWithPath: pdf)
            guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                fputs("Error: PDF not found: \(pdf)\n", stderr)
                throw ExitCode.failure
            }

            // Validate ground truth against schema FIRST (fail fast)
            let gt: CartGroundTruth
            do {
                gt = try decodeGroundTruth(groundTruth)
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                throw ExitCode.failure
            }

            let pdfData = try Data(contentsOf: pdfURL)

            // SHA256 hash (first 12 hex chars)
            let hash = SHA256.hash(data: pdfData)
            let hashStr = hash.prefix(6).map { String(format: "%02x", $0) }.joined()

            let baseDir = Dataset.datasetDir(override: dir)
            let imagesDir = baseDir.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

            let destFileName = "\(hashStr).pdf"
            let destPath = imagesDir.appendingPathComponent(destFileName)

            // Deduplicate by hash
            let metadataPath = baseDir.appendingPathComponent("metadata.jsonl")
            if FileManager.default.fileExists(atPath: metadataPath.path) {
                let existing = try String(contentsOf: metadataPath, encoding: .utf8)
                if existing.contains("images/\(destFileName)") || existing.contains("images\\/\(destFileName)") {
                    print("⚠ Already in dataset: \(destFileName)")
                    return
                }
            }

            // Copy PDF
            if !FileManager.default.fileExists(atPath: destPath.path) {
                try pdfData.write(to: destPath)
            }

            // Extract text via PDFKit
            var pdfText = ""
            #if canImport(PDFKit)
            if let pdfDoc = PDFDocument(url: destPath) {
                var pages: [String] = []
                for i in 0..<pdfDoc.pageCount {
                    if let page = pdfDoc.page(at: i), let text = page.string {
                        pages.append(text)
                    }
                }
                pdfText = pages.joined(separator: "\n")
            }
            #endif

            // Re-encode ground truth through Codable for consistent key ordering
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let gtData = try encoder.encode(gt)
            let gtJSON = String(data: gtData, encoding: .utf8) ?? "{}"

            // Wrap in gt_parse format
            let gtParseStr = "{\"gt_parse\":\(gtJSON)}"

            // Build metadata entry as ordered JSON
            // Use JSONSerialization for the outer envelope since we need string values
            let entry: [String: Any] = [
                "file_name": "images/\(destFileName)",
                "ground_truth": gtParseStr,
                "pdf_text": pdfText
            ]
            let entryData = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            let entryLine = String(data: entryData, encoding: .utf8) ?? "{}"

            // Append to metadata.jsonl
            let fileHandle: FileHandle
            if FileManager.default.fileExists(atPath: metadataPath.path) {
                fileHandle = try FileHandle(forWritingTo: metadataPath)
                fileHandle.seekToEndOfFile()
            } else {
                FileManager.default.createFile(atPath: metadataPath.path, contents: nil)
                fileHandle = try FileHandle(forWritingTo: metadataPath)
            }
            fileHandle.write((entryLine + "\n").data(using: .utf8)!)
            fileHandle.closeFile()

            print("✓ Added: \(destFileName)")
            print("  Merchant: \(gt.merchant)")
            print("  Items: \(gt.items.count)")
            print("  Total: \(gt.total)")
            print("  Text: \(pdfText.count) chars")
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate dataset integrity (files + schema)")

        @Option(name: .long, help: "Dataset directory (default: ~/.atl/dataset)")
        var dir: String?

        func run() throws {
            let baseDir = Dataset.datasetDir(override: dir)
            let metadataPath = baseDir.appendingPathComponent("metadata.jsonl")

            guard FileManager.default.fileExists(atPath: metadataPath.path) else {
                print("No dataset found at \(metadataPath.path)")
                throw ExitCode.failure
            }

            let content = try String(contentsOf: metadataPath, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

            var valid = 0
            var missing = 0
            var malformed = 0
            var schemaErrors = 0

            for (i, line) in lines.enumerated() {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let fileName = entry["file_name"] as? String else {
                    fputs("Line \(i + 1): malformed JSON\n", stderr)
                    malformed += 1
                    continue
                }

                // Check PDF exists
                let pdfPath = baseDir.appendingPathComponent(fileName)
                if !FileManager.default.fileExists(atPath: pdfPath.path) {
                    fputs("Line \(i + 1): missing PDF: \(fileName)\n", stderr)
                    missing += 1
                    continue
                }

                // Validate ground truth against schema
                if let gtStr = entry["ground_truth"] as? String,
                   let gtData = gtStr.data(using: .utf8),
                   let gtWrapper = try? JSONSerialization.jsonObject(with: gtData) as? [String: Any],
                   let gtParse = gtWrapper["gt_parse"] {
                    let gtParseData = try JSONSerialization.data(withJSONObject: gtParse)
                    let gtParseStr = String(data: gtParseData, encoding: .utf8) ?? "{}"
                    do {
                        _ = try decodeGroundTruth(gtParseStr)
                    } catch {
                        fputs("Line \(i + 1): schema error: \(error.localizedDescription)\n", stderr)
                        schemaErrors += 1
                        continue
                    }
                } else {
                    fputs("Line \(i + 1): missing or invalid ground_truth\n", stderr)
                    schemaErrors += 1
                    continue
                }

                valid += 1
            }

            print("Dataset: \(metadataPath.path)")
            print("Entries: \(lines.count)")
            print("Valid: \(valid)")
            if missing > 0 { print("Missing PDFs: \(missing)") }
            if malformed > 0 { print("Malformed: \(malformed)") }
            if schemaErrors > 0 { print("Schema errors: \(schemaErrors)") }

            if missing > 0 || malformed > 0 || schemaErrors > 0 {
                throw ExitCode.failure
            }
            print("✓ All entries valid")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List dataset entries")

        @Option(name: .long, help: "Dataset directory (default: ~/.atl/dataset)")
        var dir: String?

        func run() throws {
            let baseDir = Dataset.datasetDir(override: dir)
            let metadataPath = baseDir.appendingPathComponent("metadata.jsonl")

            guard FileManager.default.fileExists(atPath: metadataPath.path) else {
                print("No dataset found at \(metadataPath.path)")
                return
            }

            let content = try String(contentsOf: metadataPath, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

            if lines.isEmpty {
                print("Dataset is empty")
                return
            }

            for (i, line) in lines.enumerated() {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let fileName = entry["file_name"] as? String,
                      let gtStr = entry["ground_truth"] as? String,
                      let gtData = gtStr.data(using: .utf8),
                      let gtWrapper = try? JSONSerialization.jsonObject(with: gtData) as? [String: Any],
                      let gtParse = gtWrapper["gt_parse"],
                      let gtParseData = try? JSONSerialization.data(withJSONObject: gtParse),
                      let gtParseStr = String(data: gtParseData, encoding: .utf8),
                      let gt = try? decodeGroundTruth(gtParseStr) else {
                    print("\(i + 1). [malformed entry]")
                    continue
                }

                print("\(i + 1). \(gt.merchant) — \(gt.items.count) item\(gt.items.count == 1 ? "" : "s") — \(gt.total) [\(fileName)]")
            }

            print("\n\(lines.count) entries")
        }
    }

    struct Schema: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the ground truth JSON schema")

        func run() {
            print("""
            {
              "merchant": "string (required) — retailer name, lowercase",
              "items": [
                {
                  "name": "string (required) — product name",
                  "quantity": "int (required) — must be >= 1",
                  "unit_price": "string (required) — e.g. \"$249.99\"",
                  "total_price": "string (required) — quantity * unit_price"
                }
              ],
              "total": "string (required) — final total including tax/shipping",
              "subtotal": "string (optional) — pre-tax subtotal",
              "tax": "string (optional) — tax amount",
              "shipping": "string (optional) — shipping cost",
              "currency": "string (optional) — ISO 4217, defaults to USD",
              "url": "string (optional) — source URL",
              "timestamp": "string (optional) — ISO 8601",
              "discounts": [
                {
                  "name": "string (required) — discount description",
                  "amount": "string (required) — e.g. \"-$10.00\""
                }
              ],
              "notes": "string (optional) — freeform notes"
            }
            """)
        }
    }
}
