import Foundation
import Network

// MARK: - Automation Mode

/// The current automation mode - browser (web) or native (app)
enum AutomationMode: String, Codable {
    case browser
    case native
}

// MARK: - Native App Types (defined here for CommandServer, implemented in NativeController)

/// How to search for elements in native apps
enum FindBy: String, Codable {
    case any
    case label
    case value
    case identifier
    case type
}

/// What action to take when finding elements
enum FindAction: String, Codable {
    case tap
    case fill
    case exists
    case get
}

/// State of a native app
enum AppStateValue: String, Codable {
    case none
    case launching
    case running
    case suspended
    case terminated
}

/// Represents the current state of a native app
struct AppState {
    let bundleId: String?
    let state: AppStateValue
}

/// Information about a single UI element in native app snapshot
struct ElementInfo {
    let ref: String
    let type: String
    let label: String?
    let value: String?
    let identifier: String?
    let frame: CGRect
    let isHittable: Bool
    let isEnabled: Bool
}

/// Result of a native app snapshot
struct SnapshotResult {
    let elements: [ElementInfo]
    let bundleId: String?
}

/// Result of a find operation in native apps
struct FindResult {
    let found: Bool
    let ref: String?
    let element: ElementInfo?
}

/// HTTP server that receives automation commands from the host macOS app
@MainActor
final class CommandServer {
    private let port: UInt16
    private weak var controller: BrowserController?
    private var listener: NWListener?
    
    // MARK: - Native App Support
    //
    // NOTE: Native app automation runs on a SEPARATE server (port 9223) via UI Tests.
    // This browser server (port 9222) handles web automation only.
    // See: AtlBrowserUITests/NativeServer.swift for native app support.
    
    /// Current automation mode - browser only on this server
    private(set) var mode: AutomationMode = .browser

    init(port: UInt16, controller: BrowserController) {
        self.port = port
        self.controller = controller
    }

    func start() {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                print("[CommandServer] Invalid port: \(port)")
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            // Security: this HTTP command server is unauthenticated, so we must avoid binding to
            // all interfaces by default. Bind to loopback on real devices.
            //
            // Note: simulator networking can be quirky across iOS versions; if you *need* to reach
            // the listener from the host machine, you may have to relax this (or add auth + firewall).
#if !targetEnvironment(simulator)
            if let loopback = IPv4Address("127.0.0.1") {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: nwPort)
            }
#endif

            listener = try NWListener(using: parameters, on: nwPort)

            let serverPort = port
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[CommandServer] Listening on port \(serverPort)")
                case .failed(let error):
                    print("[CommandServer] Failed to start: \(error)")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            listener?.start(queue: .main)
        } catch {
            print("[CommandServer] Error starting server: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    self?.receiveRequest(connection)
                }
            case .failed(let error):
                print("[CommandServer] Connection failed: \(error)")
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                if let data = data, !data.isEmpty {
                    // Handle the request - it will manage connection lifecycle via sendResponse
                    self?.handleRequest(data, connection: connection)
                } else if isComplete || error != nil {
                    // Only cancel if no data and connection is complete or errored
                    connection.cancel()
                } else {
                    // Continue receiving more data
                    self?.receiveRequest(connection)
                }
            }
        }
    }

    private func handleRequest(_ data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendErrorResponse(connection, message: "Invalid request")
            return
        }

        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(connection, message: "Empty request")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(connection, message: "Invalid request line")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Find body (after empty line)
        var body: Data?
        if let emptyLineIndex = lines.firstIndex(of: "") {
            let bodyStart = emptyLineIndex + 1
            if bodyStart < lines.count {
                let bodyString = lines[bodyStart...].joined(separator: "\r\n")
                body = bodyString.data(using: .utf8)
            }
        }

        // Route request
        if path == "/ping" && method == "GET" {
            handlePing(connection)
        } else if path == "/command" && method == "POST" {
            // Validate Content-Type for POST requests
            let hasJsonContentType = lines.contains { line in
                line.lowercased().hasPrefix("content-type:") &&
                line.lowercased().contains("application/json")
            }
            if !hasJsonContentType && body != nil {
                sendErrorResponse(connection, message: "Content-Type must be application/json")
                return
            }
            handleCommand(body, connection: connection)
        } else {
            sendErrorResponse(connection, message: "Not found")
        }
    }

    private func handlePing(_ connection: NWConnection) {
        let body = "{\"status\":\"ok\"}"
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += body

        sendResponse(connection, data: Data(response.utf8))
    }

    private func handleCommand(_ body: Data?, connection: NWConnection) {
        guard let body = body,
              let command = try? JSONDecoder().decode(Command.self, from: body) else {
            sendErrorResponse(connection, message: "Invalid command")
            return
        }

        Task { @MainActor in
            let response = await executeCommand(command)
            guard let responseData = try? JSONEncoder().encode(response) else {
                self.sendErrorResponse(connection, message: "Failed to encode response")
                return
            }

            // Build HTTP response with proper CRLF line endings
            var httpResponse = "HTTP/1.1 200 OK\r\n"
            httpResponse += "Content-Type: application/json\r\n"
            httpResponse += "Content-Length: \(responseData.count)\r\n"
            httpResponse += "Connection: close\r\n"
            httpResponse += "\r\n"

            var fullResponse = Data(httpResponse.utf8)
            fullResponse.append(responseData)

            self.sendResponse(connection, data: fullResponse)
        }
    }

    private func executeCommand(_ command: Command) async -> CommandResponse {
        guard let controller = controller else {
            return CommandResponse(id: command.id, success: false, result: nil, error: "Controller not available")
        }

        do {
            var result: [String: Any]?

            switch command.method {
            // Navigation
            case "goto":
                if let url = command.params?["url"] as? String {
                    try await controller.goto(url)
                    // Return the current URL so caller can verify navigation worked
                    result = ["url": controller.currentURL?.absoluteString ?? url]
                }

            case "reload":
                controller.reload()

            case "goBack":
                controller.goBack()

            case "goForward":
                controller.goForward()

            case "getURL":
                result = ["url": controller.currentURL?.absoluteString ?? ""]

            case "getTitle":
                result = ["title": controller.pageTitle]

            // Interactions
            case "click":
                if let selector = command.params?["selector"] as? String {
                    try await controller.click(selector)
                }

            case "doubleClick":
                if let selector = command.params?["selector"] as? String {
                    try await controller.doubleClick(selector)
                }

            case "type":
                if let text = command.params?["text"] as? String {
                    try await controller.type(text)
                }

            case "fill":
                if let selector = command.params?["selector"] as? String,
                   let value = command.params?["value"] as? String {
                    try await controller.fill(selector, value: value)
                }

            case "press":
                if let key = command.params?["key"] as? String {
                    try await controller.press(key)
                }

            case "hover":
                if let selector = command.params?["selector"] as? String {
                    try await controller.hover(selector)
                }

            case "scrollIntoView":
                if let selector = command.params?["selector"] as? String {
                    try await controller.scrollIntoView(selector)
                }

            // Selectors
            case "querySelector":
                if let selector = command.params?["selector"] as? String {
                    if let element = try await controller.querySelector(selector) {
                        result = ["element": element]
                    }
                }

            case "querySelectorAll":
                if let selector = command.params?["selector"] as? String {
                    let elements = try await controller.querySelectorAll(selector)
                    result = ["elements": elements]
                }

            case "waitForSelector":
                if let selector = command.params?["selector"] as? String {
                    let timeout = command.params?["timeout"] as? TimeInterval ?? 30
                    try await controller.waitForSelector(selector, timeout: timeout)
                }

            case "waitForNavigation":
                _ = await controller.waitForNavigation()

            case "waitForReady":
                let timeout = command.params?["timeout"] as? TimeInterval ?? 10
                let stabilityMs = command.params?["stabilityMs"] as? Int ?? 500
                let requiredSelector = command.params?["selector"] as? String
                let readyResult = try await controller.waitForReady(
                    timeout: timeout,
                    stabilityMs: stabilityMs,
                    requiredSelector: requiredSelector
                )
                result = [
                    "ready": readyResult.ready,
                    "readyState": readyResult.readyState,
                    "domStable": readyResult.domStable,
                    "networkIdle": readyResult.networkIdle,
                    "waitedMs": readyResult.waitedMs,
                    "checks": readyResult.checks
                ]

            // Browser Profile
            case "getUserAgent":
                result = ["userAgent": controller.getUserAgent()]

            case "setUserAgent":
                // Pass { userAgent: "..." } to set; omit/empty to no-op; { userAgent: null } not representable in JSON dictionary parsing here.
                if let ua = command.params?["userAgent"] as? String {
                    controller.setUserAgent(ua)
                }
                result = ["ok": true]

            case "setContentMode":
                let modeString = (command.params?["mode"] as? String) ?? "mobile"
                let mode: BrowserController.ContentMode = (modeString.lowercased() == "desktop") ? .desktop : .mobile
                controller.setContentMode(mode)
                result = ["ok": true, "mode": mode.rawValue]

            // JavaScript
            case "evaluate":
                if let script = command.params?["script"] as? String {
                    let value = try await controller.evaluateJavaScript(script)
                    result = ["value": value ?? NSNull()]
                }

            // Screenshots (Browser mode - native screenshots use port 9223)
            case "screenshot":
                let fullPage = command.params?["fullPage"] as? Bool ?? false
                let selector = command.params?["selector"] as? String

                let imageData: Data
                if let selector = selector {
                    imageData = try await controller.takeScreenshot(selector: selector)
                } else if fullPage {
                    // Full page PDF screenshot - captures entire scrollable content
                    imageData = try await controller.takeFullPageScreenshot()
                } else {
                    imageData = try await controller.takeScreenshot()
                }
                // For fullPage, data is PDF; otherwise PNG
                result = ["data": imageData.base64EncodedString(), "format": fullPage ? "pdf" : "png", "mode": "browser"]

            // Vision Capture - full page PDF with metadata for vision-based automation
            case "captureForVision":
                // Optional pre-capture settle (reuse existing readiness heuristic)
                let preflight = command.params?["waitForReady"] as? Bool ?? false
                if preflight {
                    let timeout = command.params?["timeout"] as? TimeInterval ?? 20
                    let stabilityMs = command.params?["stabilityMs"] as? Int ?? 1500
                    let requiredSelector = command.params?["selector"] as? String
                    _ = try await controller.waitForReady(
                        timeout: timeout,
                        stabilityMs: stabilityMs,
                        requiredSelector: requiredSelector
                    )

                    let settleMs = command.params?["settleMs"] as? Int ?? 0
                    if settleMs > 0 {
                        try await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
                    }
                }

                let capture = try await controller.captureForVision()

                // Optionally save to disk if savePath is provided
                if let savePath = command.params?["savePath"] as? String,
                   let name = command.params?["name"] as? String {
                    let directory = URL(fileURLWithPath: savePath)
                    let savedPath = try controller.saveVisionCapture(capture, to: directory, name: name)
                    result = [
                        "pdf": capture.pdf.base64EncodedString(),
                        "url": capture.url,
                        "title": capture.title,
                        "timestamp": ISO8601DateFormatter().string(from: capture.timestamp),
                        "savedTo": savedPath.path
                    ]
                } else {
                    result = [
                        "pdf": capture.pdf.base64EncodedString(),
                        "url": capture.url,
                        "title": capture.title,
                        "timestamp": ISO8601DateFormatter().string(from: capture.timestamp)
                    ]
                }

            // Light Capture - text + interactives only (~9KB vs 1.1MB PDF)
            case "captureLight":
                let capture = try await controller.captureLight()
                result = capture.asDict

            // JPEG Capture - smaller than PDF, still visual
            case "captureJPEG":
                let quality = command.params?["quality"] as? Int ?? 80
                let fullPage = command.params?["fullPage"] as? Bool ?? false
                let capture = try await controller.captureJPEG(quality: quality, fullPage: fullPage)

                result = [
                    "jpeg": capture.jpeg.base64EncodedString(),
                    "url": capture.url,
                    "title": capture.title,
                    "width": capture.width,
                    "height": capture.height,
                    "quality": capture.quality,
                    "fullPage": capture.fullPage,
                    "size": capture.jpeg.count,
                    "timestamp": ISO8601DateFormatter().string(from: capture.timestamp)
                ]

            // Cookies
            case "getCookies":
                let cookies = await controller.getCookies()
                result = ["cookies": cookies]

            case "setCookies":
                if let cookies = command.params?["cookies"] as? [[String: Any]] {
                    await controller.setCookies(cookies)
                }

            case "deleteCookies":
                await controller.deleteCookies()

            // MARK: - Resilience Commands

            case "waitForAny":
                if let selectors = command.params?["selectors"] as? [String] {
                    let timeout = command.params?["timeout"] as? TimeInterval ?? 10
                    let matched = try await controller.waitForAnySelector(selectors, timeout: timeout)
                    result = ["matched": matched, "selectors": selectors]
                }

            case "extract":
                // Extract with selector chain and fallbacks
                if let selectorConfig = command.params?["selector"] as? [String: Any] {
                    let chain = selectorConfig["chain"] as? [String] ?? []
                    let fallbackScript = selectorConfig["fallbackScript"] as? String
                    let transform = selectorConfig["transform"] as? String

                    let selectorChain = SelectorChain(chain: chain, fallbackScript: fallbackScript, transform: transform)
                    let extractionResult = await controller.resolveSelector(selectorChain)

                    result = [
                        "value": extractionResult.value ?? NSNull(),
                        "selectorUsed": extractionResult.selectorUsed,
                        "wasFallback": extractionResult.wasFallback,
                        "attempts": extractionResult.attempts,
                        "success": extractionResult.success
                    ]
                }

            case "getDOMSnapshot":
                let snapshot = await controller.getDOMSnapshot()
                result = ["html": snapshot ?? ""]

            case "captureFailureArtifacts":
                let failedSelector = command.params?["failedSelector"] as? String ?? "unknown"
                let triedSelectors = command.params?["triedSelectors"] as? [String] ?? []
                let errorMsg = command.params?["error"] as? String ?? "Unknown error"

                let artifacts = await controller.captureFailureArtifacts(
                    failedSelector: failedSelector,
                    triedSelectors: triedSelectors,
                    error: errorMsg
                )

                result = [
                    "screenshot": artifacts.screenshot?.base64EncodedString() ?? "",
                    "fullPagePdf": artifacts.fullPagePdf?.base64EncodedString() ?? "",
                    "domSnapshot": artifacts.domSnapshot ?? "",
                    "failedSelector": artifacts.failedSelector,
                    "timestamp": ISO8601DateFormatter().string(from: artifacts.timestamp)
                ]

            // MARK: - Extraction V2 (Production-Safe)

            case "extractV2":
                // Extract with V2 selector chain, page validation, and confidence scoring
                if let selectorConfig = command.params?["selector"] as? [String: Any] {
                    let chain = selectorConfig["chain"] as? [String] ?? []
                    let fallbackPattern = selectorConfig["fallbackPattern"] as? String
                    let transform = selectorConfig["transform"] as? String

                    // Parse fallback ranking config
                    var fallbackRanking: CandidateRankingConfig? = nil
                    if let rankingConfig = selectorConfig["fallbackRanking"] as? [String: Any] {
                        fallbackRanking = CandidateRankingConfig(
                            preferRange: rankingConfig["preferRange"] as? [Double],
                            penalizeOutsideRange: rankingConfig["penalizeOutsideRange"] as? Double,
                            avoidContextPatterns: rankingConfig["avoidContextPatterns"] as? [String],
                            avoidContextPenalty: rankingConfig["avoidContextPenalty"] as? Double,
                            preferContextPatterns: rankingConfig["preferContextPatterns"] as? [String],
                            preferContextBonus: rankingConfig["preferContextBonus"] as? Double
                        )
                    }

                    let selectorChain = SelectorChainV2(
                        chain: chain,
                        fallbackPattern: fallbackPattern,
                        fallbackRanking: fallbackRanking,
                        transform: transform
                    )

                    // Parse page validation rules
                    var pageValidation: PageValidationRules? = nil
                    if let validationConfig = command.params?["pageValidation"] as? [String: Any] {
                        pageValidation = PageValidationRules(
                            urlContains: validationConfig["urlContains"] as? [String],
                            urlNotContains: validationConfig["urlNotContains"] as? [String],
                            titleContains: validationConfig["titleContains"] as? [String],
                            titleNotContains: validationConfig["titleNotContains"] as? [String],
                            requiredElements: validationConfig["requiredElements"] as? [String],
                            forbiddenElements: validationConfig["forbiddenElements"] as? [String],
                            minContentLength: validationConfig["minContentLength"] as? Int
                        )
                    }

                    // Parse value validation rules
                    var valueValidation: ValidationRule? = nil
                    if let valConfig = command.params?["validation"] as? [String: Any] {
                        let typeStr = valConfig["type"] as? String
                        let valType: ValidationRule.ValidationType? = typeStr.flatMap { ValidationRule.ValidationType(rawValue: $0) }
                        valueValidation = ValidationRule(
                            type: valType,
                            required: valConfig["required"] as? Bool,
                            minLength: valConfig["minLength"] as? Int,
                            maxLength: valConfig["maxLength"] as? Int,
                            range: valConfig["range"] as? [Double],
                            pattern: valConfig["pattern"] as? String,
                            notContains: valConfig["notContains"] as? [String],
                            contains: valConfig["contains"] as? [String]
                        )
                    }

                    let extractionResult = await controller.resolveSelectorV2(
                        chain: selectorChain,
                        pageValidation: pageValidation,
                        valueValidation: valueValidation
                    )

                    // Build candidates array for result
                    var candidatesArray: [[String: Any]] = []
                    if let candidates = extractionResult.candidates {
                        for c in candidates {
                            candidatesArray.append([
                                "value": c.value,
                                "source": c.source,
                                "score": c.score,
                                "context": c.context ?? "",
                                "position": c.position,
                                "reasoning": c.reasoning
                            ])
                        }
                    }

                    // Build page validation result
                    var pageValidationResult: [String: Any] = [
                        "passed": extractionResult.pageValidation.passed,
                        "failedChecks": extractionResult.pageValidation.failedChecks
                    ]
                    var checksArray: [[String: Any]] = []
                    for check in extractionResult.pageValidation.checks {
                        checksArray.append([
                            "name": check.name,
                            "passed": check.passed,
                            "expected": check.expected ?? "",
                            "actual": check.actual ?? ""
                        ])
                    }
                    pageValidationResult["checks"] = checksArray

                    result = [
                        "value": extractionResult.value?.value ?? NSNull(),
                        "confidence": extractionResult.confidence,
                        "confidenceLevel": extractionResult.confidenceLevel,
                        "method": extractionResult.method.rawValue,
                        "selectorUsed": extractionResult.selectorUsed ?? "",
                        "candidates": candidatesArray,
                        "validationErrors": extractionResult.validationErrors,
                        "pageValidation": pageValidationResult,
                        "isReliable": extractionResult.isReliable,
                        "isUsable": extractionResult.isUsable
                    ]
                }

            // MARK: - Selector Cache

            case "selectorCache.learn":
                let action = command.params?["action"] as? String ?? ""
                let selector = command.params?["selector"] as? String ?? ""
                let url = command.params?["url"] as? String ?? controller.currentURL?.absoluteString ?? ""
                let attributes = command.params?["attributes"] as? [String: String] ?? [:]

                SelectorCache.shared.learn(action: action, selector: selector, url: url, attributes: attributes)
                result = ["learned": true, "action": action, "selector": selector]

            case "selectorCache.recall":
                let action = command.params?["action"] as? String ?? ""
                let url = command.params?["url"] as? String ?? controller.currentURL?.absoluteString ?? ""

                if let cached = SelectorCache.shared.recall(action: action, url: url) {
                    result = [
                        "found": true,
                        "selector": cached.selector,
                        "action": cached.action,
                        "successCount": cached.successCount,
                        "failCount": cached.failCount,
                        "reliability": cached.reliability,
                        "lastUsed": ISO8601DateFormatter().string(from: cached.lastUsed)
                    ]
                } else {
                    result = ["found": false, "action": action]
                }

            case "selectorCache.recordFailure":
                let action = command.params?["action"] as? String ?? ""
                let selector = command.params?["selector"] as? String ?? ""
                let url = command.params?["url"] as? String ?? controller.currentURL?.absoluteString ?? ""

                SelectorCache.shared.recordFailure(action: action, selector: selector, url: url)
                result = ["recorded": true, "action": action]

            case "selectorCache.getAll":
                let url = command.params?["url"] as? String ?? controller.currentURL?.absoluteString ?? ""
                let selectors = SelectorCache.shared.getAll(for: url)

                var selectorsDict: [String: [String: Any]] = [:]
                for (action, cached) in selectors {
                    selectorsDict[action] = [
                        "selector": cached.selector,
                        "successCount": cached.successCount,
                        "failCount": cached.failCount,
                        "reliability": cached.reliability,
                        "lastUsed": ISO8601DateFormatter().string(from: cached.lastUsed)
                    ]
                }
                result = ["selectors": selectorsDict, "count": selectors.count]

            case "selectorCache.getDomains":
                let domains = SelectorCache.shared.getAllDomains()
                result = ["domains": domains, "count": domains.count]

            case "selectorCache.getStats":
                result = SelectorCache.shared.getStats()

            case "selectorCache.clear":
                if let domain = command.params?["domain"] as? String {
                    SelectorCache.shared.clear(domain: domain)
                    result = ["cleared": domain]
                } else {
                    SelectorCache.shared.clearAll()
                    result = ["cleared": "all"]
                }

            case "selectorCache.export":
                let cache = SelectorCache.shared.exportCache()
                var exportData: [String: Any] = [:]

                for (domain, domainCache) in cache {
                    var domainData: [String: Any] = [
                        "lastUpdated": ISO8601DateFormatter().string(from: domainCache.lastUpdated),
                        "selectors": [:]
                    ]

                    var selectorsData: [String: [String: Any]] = [:]
                    for (action, cached) in domainCache.selectors {
                        selectorsData[action] = [
                            "selector": cached.selector,
                            "successCount": cached.successCount,
                            "failCount": cached.failCount,
                            "reliability": cached.reliability,
                            "discoveredAt": ISO8601DateFormatter().string(from: cached.discoveredAt),
                            "lastUsed": ISO8601DateFormatter().string(from: cached.lastUsed),
                            "attributes": cached.attributes
                        ]
                    }
                    domainData["selectors"] = selectorsData
                    exportData[domain] = domainData
                }

                result = ["cache": exportData, "domains": cache.count]

            // MARK: - Touch Gestures (Both Modes)

            case "tap":
                let x = (command.params?["x"] as? Double) ?? Double(command.params?["x"] as? Int ?? 0)
                let y = (command.params?["y"] as? Double) ?? Double(command.params?["y"] as? Int ?? 0)
                let point = CGPoint(x: x, y: y)
                
                let gestureSimulator = TouchGestureSimulator(webView: controller.webView)
                try await gestureSimulator.tap(at: point)
                result = ["tapped": true, "x": x, "y": y, "mode": "browser"]

            case "longPress":
                let x = (command.params?["x"] as? Double) ?? Double(command.params?["x"] as? Int ?? 0)
                let y = (command.params?["y"] as? Double) ?? Double(command.params?["y"] as? Int ?? 0)
                let duration = command.params?["duration"] as? Double ?? 0.5
                let point = CGPoint(x: x, y: y)
                
                let gestureSimulator = TouchGestureSimulator(webView: controller.webView)
                try await gestureSimulator.longPress(at: point, duration: duration)
                result = ["longPressed": true, "x": x, "y": y, "duration": duration, "mode": "browser"]

            case "swipe":
                let gestureSimulator = TouchGestureSimulator(webView: controller.webView)
                
                if let directionStr = command.params?["direction"] as? String,
                   let direction = SwipeDirection(rawValue: directionStr.lowercased()) {
                    let distance = command.params?["distance"] as? Double ?? 300
                    let duration = command.params?["duration"] as? Double ?? 0.3
                    try await gestureSimulator.swipe(direction: direction, distance: CGFloat(distance), duration: duration)
                    result = ["swiped": true, "direction": directionStr, "distance": distance, "mode": "browser"]
                } else {
                    let fromX = command.params?["fromX"] as? Double ?? command.params?["startX"] as? Double ?? 0
                    let fromY = command.params?["fromY"] as? Double ?? command.params?["startY"] as? Double ?? 0
                    let toX = command.params?["toX"] as? Double ?? command.params?["endX"] as? Double ?? 0
                    let toY = command.params?["toY"] as? Double ?? command.params?["endY"] as? Double ?? 0
                    let duration = command.params?["duration"] as? Double ?? 0.3
                    
                    try await gestureSimulator.swipe(
                        from: CGPoint(x: fromX, y: fromY),
                        to: CGPoint(x: toX, y: toY),
                        duration: duration
                    )
                    result = ["swiped": true, "from": ["x": fromX, "y": fromY], "to": ["x": toX, "y": toY], "mode": "browser"]
                }

            case "pinch":
                let scale = command.params?["scale"] as? Double ?? 1.5
                let duration = command.params?["duration"] as? Double ?? 0.3
                
                let gestureSimulator = TouchGestureSimulator(webView: controller.webView)
                try await gestureSimulator.pinch(scale: CGFloat(scale), duration: duration)
                result = ["pinched": true, "scale": scale, "mode": "browser"]

            // MARK: - Native App Commands
            //
            // Native app automation uses a SEPARATE server on port 9223.
            // Start it with: xcodebuild test -workspace AtlBrowser.xcworkspace -scheme AtlBrowser \
            //   -destination 'id=<SIMULATOR_UDID>' -only-testing:AtlBrowserUITests/NativeServer/testNativeServer
            
            case "openApp", "closeApp", "snapshot", "tapRef", "fillRef", "focusRef", "find":
                let nativeError = "Native app commands use port 9223 (this is the browser server on 9222). " +
                    "Start the native server with: xcodebuild test -only-testing:AtlBrowserUITests/NativeServer/testNativeServer"
                return CommandResponse(id: command.id, success: false, result: nil, error: nativeError)

            case "appState":
                // Return browser-only state
                result = [
                    "mode": "browser",
                    "bundleId": NSNull(),
                    "state": "none",
                    "note": "Native app commands use port 9223"
                ]

            case "openBrowser":
                // No-op on browser server, already in browser mode
                result = ["mode": "browser"]

            // MARK: - Mode-Specific Browser Commands (Add validation)

            case "markElements":
                guard mode == .browser else {
                    return CommandResponse(id: command.id, success: false, result: nil, error: "markElements requires browser mode (use snapshot for native)")
                }
                let elements = try await controller.markInteractiveElements()
                result = ["elements": elements, "count": elements.count]

            case "markAll":
                guard mode == .browser else {
                    return CommandResponse(id: command.id, success: false, result: nil, error: "markAll requires browser mode")
                }
                let elements = try await controller.markAllInteractiveElements()
                result = ["elements": elements, "count": elements.count]

            case "unmarkElements":
                guard mode == .browser else {
                    return CommandResponse(id: command.id, success: false, result: nil, error: "unmarkElements requires browser mode")
                }
                try await controller.unmarkElements()
                result = ["cleared": true]

            case "clickMark":
                guard mode == .browser else {
                    return CommandResponse(id: command.id, success: false, result: nil, error: "clickMark requires browser mode (use tapRef for native)")
                }
                if let label = command.params?["label"] as? Int {
                    try await controller.clickByMark(label)
                    result = ["clicked": label]
                }

            case "getMarkInfo":
                guard mode == .browser else {
                    return CommandResponse(id: command.id, success: false, result: nil, error: "getMarkInfo requires browser mode")
                }
                if let label = command.params?["label"] as? Int {
                    if let info = try await controller.getMarkInfo(label) {
                        result = info
                    }
                }

            // MARK: - ATL State Commands (Phase 1)
            
            case "getATLState":
                if let state = try await controller.getATLState() {
                    result = state
                } else {
                    result = ["ready": false, "error": "ATL bootstrap not initialized"]
                }
            
            case "clearATLState":
                try await controller.clearATLState()
                result = ["cleared": true]
            
            case "getRecentMutations":
                let limit = command.params?["limit"] as? Int ?? 20
                let mutations = try await controller.getRecentMutations(limit: limit)
                result = ["mutations": mutations, "count": mutations.count]
            
            case "getRecentNetworkRequests":
                let limit = command.params?["limit"] as? Int ?? 20
                let requests = try await controller.getRecentNetworkRequests(limit: limit)
                result = ["requests": requests, "count": requests.count]
            
            case "getJSErrors":
                let errors = try await controller.getJSErrors()
                result = ["errors": errors, "count": errors.count]
            
            case "waitForDOMStable":
                let stabilityMs = command.params?["stabilityMs"] as? Int ?? 500
                let timeout = command.params?["timeout"] as? TimeInterval ?? 10
                let stable = try await controller.waitForDOMStable(stabilityMs: stabilityMs, timeout: timeout)
                result = ["stable": stable, "stabilityMs": stabilityMs]
            
            case "discoverAll":
                let elements = try await controller.discoverAllElements()
                result = ["elements": elements, "count": elements.count]
            
            case "discoverAndMarkAll":
                let elements = try await controller.discoverAndMarkAll()
                result = ["elements": elements, "count": elements.count]
            
            // MARK: - Agent Snapshot (Vision + Text + Marks in one call)
            
            case "agentSnapshot":
                // Wait for page to stabilize first
                let stabilityMs = command.params?["stabilityMs"] as? Int ?? 1000
                _ = try await controller.waitForDOMStable(stabilityMs: stabilityMs, timeout: 10)
                
                // Mark all elements
                let elements = try await controller.markAllInteractiveElements()
                
                // Build compact text representation of marks
                var marksText = ""
                for el in elements {
                    guard let label = el["label"] as? Int,
                          let text = el["text"] as? String else { continue }
                    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                        .prefix(60)
                    if !cleanText.isEmpty {
                        let tag = (el["tagName"] as? String) ?? "?"
                        marksText += "[\(label)] \(cleanText) <\(tag)>\n"
                    }
                }
                
                // Capture PDF
                let includePdf = command.params?["pdf"] as? Bool ?? true
                var pdfBase64: String? = nil
                if includePdf {
                    let pdfData = try await controller.takeFullPageScreenshot()
                    pdfBase64 = pdfData.base64EncodedString()
                }
                
                // Get page text (condensed)
                let textScript = """
                document.body.innerText.substring(0, 5000)
                """
                let pageText = try await controller.evaluateJavaScript(textScript) as? String ?? ""
                
                result = [
                    "url": controller.currentURL?.absoluteString ?? "",
                    "title": controller.pageTitle,
                    "marks": marksText,
                    "markCount": elements.count,
                    "text": pageText,
                    "pdf": pdfBase64 as Any
                ]
            
            // Text-based click - find element by text content and click it
            case "clickText":
                guard let searchText = command.params?["text"] as? String else {
                    return CommandResponse(id: command.id, success: false, result: nil, error: "Missing 'text' parameter")
                }
                
                let exact = command.params?["exact"] as? Bool ?? false
                let clickResult = try await controller.clickByText(searchText, exact: exact)
                result = clickResult
            
            // Compact mark output - just label:text pairs
            case "markCompact":
                let elements = try await controller.markAllInteractiveElements()
                var lines: [String] = []
                for el in elements {
                    guard let label = el["label"] as? Int,
                          let text = el["text"] as? String else { continue }
                    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                        .prefix(50)
                    if !cleanText.isEmpty {
                        lines.append("\(label):\(cleanText)")
                    }
                }
                result = ["marks": lines.joined(separator: "\n"), "count": elements.count]

            default:
                return CommandResponse(id: command.id, success: false, result: nil, error: "Unknown command: \(command.method)")
            }

            // Convert result to AnyCodable
            var codableResult: [String: AnyCodable]?
            if let result = result {
                codableResult = result.mapValues { AnyCodable($0) }
            }

            return CommandResponse(id: command.id, success: true, result: codableResult, error: nil)

        } catch {
            return CommandResponse(id: command.id, success: false, result: nil, error: error.localizedDescription)
        }
    }

    private func sendResponse(_ connection: NWConnection, data: Data) {
        // Send the response with finalMessage context to signal end of data
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
            if let error = error {
                print("[CommandServer] Send error: \(error)")
            }
            // Wait for TCP to actually transmit the data before closing
            // contentProcessed means queued, not transmitted
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                connection.cancel()
            }
        })
    }

    private func sendErrorResponse(_ connection: NWConnection, message: String) {
        let body = "{\"error\":\"\(message)\"}"
        var response = "HTTP/1.1 400 Bad Request\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += body

        sendResponse(connection, data: Data(response.utf8))
    }
}

// MARK: - Command Types

struct Command: Codable {
    let id: String
    let method: String
    let params: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case id, method, params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)

        if let paramsData = try? container.decode([String: AnyCodable].self, forKey: .params) {
            params = paramsData.mapValues { $0.value }
        } else {
            params = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)

        if let params = params {
            try container.encode(params.mapValues { AnyCodable($0) }, forKey: .params)
        }
    }
}

struct CommandResponse: Codable {
    let id: String
    let success: Bool
    let result: [String: AnyCodable]?
    let error: String?
}

// MARK: - AnyCodable Helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let data as Data:
            try container.encode(data.base64EncodedString())
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            // Try to convert to string for other types
            try container.encode(String(describing: value))
        }
    }
}
