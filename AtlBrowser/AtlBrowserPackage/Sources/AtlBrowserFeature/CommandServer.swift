import Foundation
import Network

/// HTTP server that receives automation commands from the host macOS app
@MainActor
final class CommandServer {
    private let port: UInt16
    private weak var controller: BrowserController?
    private var listener: NWListener?

    init(port: UInt16, controller: BrowserController) {
        self.port = port
        self.controller = controller
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

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

            // JavaScript
            case "evaluate":
                if let script = command.params?["script"] as? String {
                    let value = try await controller.evaluateJavaScript(script)
                    result = ["value": value ?? NSNull()]
                }

            // Screenshots
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
                result = ["data": imageData.base64EncodedString(), "format": fullPage ? "pdf" : "png"]

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
