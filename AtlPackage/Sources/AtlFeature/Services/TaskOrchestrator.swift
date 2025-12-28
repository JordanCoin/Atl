import Foundation
import SwiftUI

// MARK: - Task Orchestrator

/// Orchestrates automation tasks across multiple simulators using LLM for tool selection
@MainActor
public class TaskOrchestrator: ObservableObject {
    public static let shared = TaskOrchestrator()

    @Published public var activeExecutions: [UUID: TaskExecution] = [:]
    @Published public var completedExecutions: [TaskExecutionResult] = []

    private let httpBridge = HTTPBridgeClient()
    private let axeClient = AXeClient()
    private let copyAppClient = CopyAppClient()

    private init() {}

    // MARK: - Execute Task

    /// Execute a task on one or more simulators
    public func execute(
        task: AutomationTask,
        on simulators: [SimulatorInfo],
        variables: [String: String] = [:],
        useLLM: Bool = true
    ) async -> [TaskExecutionResult] {

        var results: [TaskExecutionResult] = []

        // Execute on each simulator sequentially
        for simulator in simulators {
            let result = await executeOnSimulator(
                task: task,
                simulator: simulator,
                variables: variables,
                useLLM: useLLM
            )
            results.append(result)
        }

        completedExecutions.append(contentsOf: results)
        return results
    }

    /// Execute task on a single simulator
    private func executeOnSimulator(
        task: AutomationTask,
        simulator: SimulatorInfo,
        variables: [String: String],
        useLLM: Bool
    ) async -> TaskExecutionResult {

        let executionId = UUID()
        let execution = TaskExecution(
            id: executionId,
            taskId: task.id,
            simulatorUDID: simulator.udid,
            simulatorName: simulator.name,
            status: .running,
            currentStepIndex: 0,
            totalSteps: task.steps.count
        )

        await MainActor.run {
            activeExecutions[executionId] = execution
        }

        var stepResults: [StepResult] = []
        var extractedData: [String: Any] = [:]
        var lastError: String?
        let startTime = Date()

        for (index, step) in task.steps.enumerated() {
            await MainActor.run {
                activeExecutions[executionId]?.currentStepIndex = index
                activeExecutions[executionId]?.currentStepDescription = step.description
            }

            let stepStart = Date()

            // Substitute variables in action
            let resolvedAction = substituteVariables(in: step.action, with: variables)

            // Determine which tool to use
            let tool = useLLM
                ? await selectToolWithLLM(for: resolvedAction, simulator: simulator)
                : selectToolHeuristically(for: resolvedAction)

            // Execute the action
            let result = await executeAction(
                resolvedAction,
                using: tool,
                simulator: simulator,
                extractedData: &extractedData
            )

            // Save screenshot if present
            var screenshotPath: String?
            if let screenshotData = result.screenshot {
                let path = "/tmp/step-screenshot-\(UUID().uuidString).png"
                try? screenshotData.write(to: URL(fileURLWithPath: path))
                screenshotPath = path
            }

            let stepResult = StepResult(
                id: UUID(),
                stepId: step.id,
                toolUsed: tool,
                success: result.success,
                message: result.message,
                duration: Date().timeIntervalSince(stepStart),
                screenshotPath: screenshotPath
            )

            stepResults.append(stepResult)

            if !result.success && !step.optional {
                lastError = result.message
                break
            }

            // Wait after step if specified
            if step.waitAfter > 0 {
                try? await Task.sleep(nanoseconds: UInt64(step.waitAfter * 1_000_000_000))
            }
        }

        let endTime = Date()
        let finalStatus: ExecutionStatus = lastError == nil ? .completed : .failed

        await MainActor.run {
            activeExecutions.removeValue(forKey: executionId)
        }

        return TaskExecutionResult(
            id: executionId,
            taskId: task.id,
            simulatorUDID: simulator.udid,
            status: finalStatus,
            stepResults: stepResults,
            startTime: startTime,
            endTime: endTime,
            error: lastError
        )
    }

    // MARK: - Tool Selection

    /// Use LLM to select the best tool for an action
    private func selectToolWithLLM(for action: TaskAction, simulator: SimulatorInfo) async -> AutomationTool {
        // For now, use heuristic selection
        // TODO: Integrate with Claude API for intelligent tool selection
        // The LLM would consider:
        // - Current page state
        // - Action type
        // - Previous action results
        // - Simulator state

        return selectToolHeuristically(for: action)
    }

    /// Heuristic tool selection based on action type
    /// PREFER HTTP BRIDGE (server) for everything it supports
    private func selectToolHeuristically(for action: TaskAction) -> AutomationTool {
        switch action {
        // HTTP Bridge handles all DOM/web interactions
        case .click(let target):
            switch target {
            case .selector: return .httpBridge
            case .text: return .httpBridge      // JS can find by text
            case .coordinates: return .axe      // Native tap for coordinates
            case .label: return .axe            // AXe for accessibility labels
            }

        case .fill, .extractText, .extractAttribute, .evaluate:
            return .httpBridge  // All JS/DOM operations

        case .goto, .goBack, .goForward, .reload:
            return .httpBridge  // Navigation via server

        case .waitForElement, .waitForNavigation:
            return .httpBridge  // JS-based waiting

        case .type:
            return .httpBridge  // Server can type into focused element

        case .scroll:
            return .httpBridge  // Try JS scroll first, fall back to axe

        case .tap:
            return .axe  // Native tap for coordinates outside WebView

        case .screenshot:
            return .httpBridge  // Server captures WebView content

        case .saveCookies, .loadCookies, .deleteCookies:
            return .httpBridge  // Cookie management via server

        case .pressButton, .gesture:
            return .axe  // Hardware buttons MUST use native tools

        case .waitForTime:
            return .combined  // Just a delay, no tool needed

        case .checkElementExists:
            return .httpBridge  // JS can check element existence
        }
    }

    // MARK: - Action Execution

    private func executeAction(
        _ action: TaskAction,
        using tool: AutomationTool,
        simulator: SimulatorInfo,
        extractedData: inout [String: Any]
    ) async -> ActionResult {

        do {
            switch action {
            case .goto(let url):
                try await httpBridge.goto(url, simulator: simulator)
                return ActionResult(success: true, message: "Navigated to \(url)")

            case .goBack:
                try await httpBridge.goBack(simulator: simulator)
                return ActionResult(success: true, message: "Went back")

            case .goForward:
                try await httpBridge.goForward(simulator: simulator)
                return ActionResult(success: true, message: "Went forward")

            case .reload:
                try await httpBridge.reload(simulator: simulator)
                return ActionResult(success: true, message: "Reloaded page")

            case .click(let target):
                switch target {
                case .selector(let selector):
                    try await httpBridge.click(selector, simulator: simulator)
                case .coordinates(let x, let y):
                    try await copyAppClient.click(x: x, y: y, simulator: simulator)
                case .label(let label):
                    try await axeClient.tap(label: label, simulator: simulator)
                case .text(let text):
                    try await httpBridge.clickByText(text, simulator: simulator)
                }
                return ActionResult(success: true, message: "Clicked target")

            case .type(let text):
                // Use server for typing (types into focused element)
                try await httpBridge.type(text, simulator: simulator)
                return ActionResult(success: true, message: "Typed '\(text)'")

            case .fill(let target, let value):
                if case .selector(let selector) = target {
                    try await httpBridge.fill(selector, value: value, simulator: simulator)
                }
                return ActionResult(success: true, message: "Filled with '\(value)'")

            case .scroll(let direction):
                let gesture: TaskSimulatorGesture
                switch direction {
                case .up: gesture = .scrollUp
                case .down: gesture = .scrollDown
                case .left: gesture = .scrollLeft
                case .right: gesture = .scrollRight
                }
                try await axeClient.gesture(gesture, simulator: simulator)
                return ActionResult(success: true, message: "Scrolled \(direction)")

            case .tap(let x, let y):
                try await copyAppClient.click(x: x, y: y, simulator: simulator)
                return ActionResult(success: true, message: "Tapped at (\(x), \(y))")

            case .waitForElement(let selector, let timeout):
                try await httpBridge.waitForSelector(selector, timeout: timeout, simulator: simulator)
                return ActionResult(success: true, message: "Element found: \(selector)")

            case .waitForNavigation(let timeout):
                try await httpBridge.waitForNavigation(timeout: timeout, simulator: simulator)
                return ActionResult(success: true, message: "Navigation complete")

            case .waitForTime(let seconds):
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return ActionResult(success: true, message: "Waited \(seconds)s")

            case .extractText(let selector, let saveAs):
                let text = try await httpBridge.extractText(selector, simulator: simulator)
                extractedData[saveAs] = text
                return ActionResult(success: true, message: "Extracted text: \(text.prefix(50))...")

            case .extractAttribute(let selector, let attribute, let saveAs):
                let value = try await httpBridge.extractAttribute(selector, attribute: attribute, simulator: simulator)
                extractedData[saveAs] = value
                return ActionResult(success: true, message: "Extracted \(attribute)")

            case .screenshot(let saveAs):
                // Use server for WebView screenshots (faster, no device frame)
                let data = try await httpBridge.screenshot(simulator: simulator)
                extractedData[saveAs] = data
                return ActionResult(success: true, message: "Screenshot captured", screenshot: data)

            case .saveCookies(let domain):
                try await httpBridge.saveCookies(for: domain, simulator: simulator)
                return ActionResult(success: true, message: "Cookies saved for \(domain)")

            case .loadCookies(let domain):
                try await httpBridge.loadCookies(for: domain, simulator: simulator)
                return ActionResult(success: true, message: "Cookies loaded for \(domain)")

            case .deleteCookies:
                try await httpBridge.deleteCookies(simulator: simulator)
                return ActionResult(success: true, message: "Cookies deleted")

            case .evaluate(let script, let saveAs):
                let result = try await httpBridge.evaluate(script, simulator: simulator)
                if let key = saveAs {
                    extractedData[key] = result
                }
                return ActionResult(success: true, message: "Evaluated script")

            case .pressButton(let button):
                try await axeClient.button(button, simulator: simulator)
                return ActionResult(success: true, message: "Pressed \(button)")

            case .gesture(let preset):
                try await axeClient.gesture(preset, simulator: simulator)
                return ActionResult(success: true, message: "Performed gesture")

            case .checkElementExists(let selector, let saveAs):
                let exists = try await httpBridge.elementExists(selector, simulator: simulator)
                extractedData[saveAs] = exists
                return ActionResult(success: true, message: "Element exists: \(exists)")
            }

        } catch {
            return ActionResult(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Variable Substitution

    private func substituteVariables(in action: TaskAction, with variables: [String: String]) -> TaskAction {
        func substitute(_ text: String) -> String {
            var result = text
            for (key, value) in variables {
                result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
            return result
        }

        switch action {
        case .goto(let url):
            return .goto(url: substitute(url))
        case .type(let text):
            return .type(text: substitute(text))
        case .fill(let target, let value):
            return .fill(target: target, value: substitute(value))
        case .evaluate(let script, let saveAs):
            return .evaluate(script: substitute(script), saveAs: saveAs)
        default:
            return action
        }
    }
}

// MARK: - Supporting Types

public struct SimulatorInfo: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let udid: String
    public let name: String
    public let state: String

    public init(id: UUID = UUID(), udid: String, name: String, state: String = "Booted") {
        self.id = id
        self.udid = udid
        self.name = name
        self.state = state
    }
}

public struct TaskExecution: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let taskId: UUID
    public let simulatorUDID: String
    public let simulatorName: String
    public var status: ExecutionStatus
    public var currentStepIndex: Int
    public var totalSteps: Int
    public var currentStepDescription: String?

    public var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStepIndex) / Double(totalSteps)
    }
}

public struct ActionResult {
    public let success: Bool
    public let message: String?
    public let screenshot: Data?

    public init(success: Bool, message: String? = nil, screenshot: Data? = nil) {
        self.success = success
        self.message = message
        self.screenshot = screenshot
    }
}

// MARK: - HTTP Bridge Client

/// Client for the AtlBrowser HTTP command server
final class HTTPBridgeClient: @unchecked Sendable {
    private let baseURL = "http://localhost:9222"

    func goto(_ url: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("goto", params: ["url": url])
    }

    func goBack(simulator: SimulatorInfo) async throws {
        try await sendCommand("goBack")
    }

    func goForward(simulator: SimulatorInfo) async throws {
        try await sendCommand("goForward")
    }

    func reload(simulator: SimulatorInfo) async throws {
        try await sendCommand("reload")
    }

    func click(_ selector: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("click", params: ["selector": selector])
    }

    func clickByText(_ text: String, simulator: SimulatorInfo) async throws {
        let script = """
        (function() {
            const elements = document.querySelectorAll('*');
            for (const el of elements) {
                if (el.textContent?.includes('\(text)') && el.children.length === 0) {
                    el.click();
                    return true;
                }
            }
            return false;
        })()
        """
        try await sendCommand("evaluate", params: ["script": script])
    }

    func fill(_ selector: String, value: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("fill", params: ["selector": selector, "value": value])
    }

    func type(_ text: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("type", params: ["text": text])
    }

    func press(_ key: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("press", params: ["key": key])
    }

    func screenshot(simulator: SimulatorInfo) async throws -> Data {
        let result = try await sendCommandWithResult("screenshot")
        guard let base64 = result["data"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw OrchestratorError.invalidResponse
        }
        return data
    }

    func getTitle(simulator: SimulatorInfo) async throws -> String {
        let result = try await sendCommandWithResult("getTitle")
        return result["title"] as? String ?? ""
    }

    func getURL(simulator: SimulatorInfo) async throws -> String {
        let result = try await sendCommandWithResult("getURL")
        return result["url"] as? String ?? ""
    }

    func hover(_ selector: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("hover", params: ["selector": selector])
    }

    func doubleClick(_ selector: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("doubleClick", params: ["selector": selector])
    }

    func scrollIntoView(_ selector: String, simulator: SimulatorInfo) async throws {
        try await sendCommand("scrollIntoView", params: ["selector": selector])
    }

    func waitForSelector(_ selector: String, timeout: TimeInterval, simulator: SimulatorInfo) async throws {
        try await sendCommand("waitForSelector", params: ["selector": selector, "timeout": timeout])
    }

    func waitForNavigation(timeout: TimeInterval, simulator: SimulatorInfo) async throws {
        try await sendCommand("waitForNavigation", params: ["timeout": timeout])
    }

    func extractText(_ selector: String, simulator: SimulatorInfo) async throws -> String {
        let result = try await sendCommandWithResult("evaluate", params: [
            "script": "document.querySelector('\(selector)')?.textContent || ''"
        ])
        return result["value"] as? String ?? ""
    }

    func extractAttribute(_ selector: String, attribute: String, simulator: SimulatorInfo) async throws -> String {
        let result = try await sendCommandWithResult("evaluate", params: [
            "script": "document.querySelector('\(selector)')?.getAttribute('\(attribute)') || ''"
        ])
        return result["value"] as? String ?? ""
    }

    func elementExists(_ selector: String, simulator: SimulatorInfo) async throws -> Bool {
        let result = try await sendCommandWithResult("evaluate", params: [
            "script": "document.querySelector('\(selector)') !== null"
        ])
        return result["value"] as? Bool ?? false
    }

    func evaluate(_ script: String, simulator: SimulatorInfo) async throws -> Any? {
        let result = try await sendCommandWithResult("evaluate", params: ["script": script])
        return result["value"]
    }

    func saveCookies(for domain: String, simulator: SimulatorInfo) async throws {
        // Get cookies from browser
        let result = try await sendCommandWithResult("getCookies")
        guard let cookies = result["cookies"] else { return }

        // Save to file
        let cookieData = try JSONSerialization.data(withJSONObject: cookies)
        let url = cookieFileURL(for: domain)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cookieData.write(to: url)
    }

    func loadCookies(for domain: String, simulator: SimulatorInfo) async throws {
        let url = cookieFileURL(for: domain)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        let cookies = try JSONSerialization.jsonObject(with: data)
        try await sendCommand("setCookies", params: ["cookies": cookies])
    }

    func deleteCookies(simulator: SimulatorInfo) async throws {
        try await sendCommand("deleteCookies")
    }

    private func cookieFileURL(for domain: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Atl/Cookies/\(domain).json")
    }

    private func sendCommand(_ method: String, params: [String: Any] = [:]) async throws {
        _ = try await sendCommandWithResult(method, params: params)
    }

    private func sendCommandWithResult(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)/command")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await URLSession.shared.data(for: request)

        // Debug: print raw response
        let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        print("[HTTPBridge] Method: \(method), Status: \((httpResponse as? HTTPURLResponse)?.statusCode ?? -1), Response: \(rawResponse.prefix(500))")

        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OrchestratorError.cannotParseResponse(rawResponse)
        }

        if let success = response["success"] as? Bool, !success {
            throw OrchestratorError.commandFailed(response["error"] as? String ?? "Unknown error")
        }

        return response["result"] as? [String: Any] ?? [:]
    }
}

// MARK: - AXe Client

/// Client for AXe simulator automation
final class AXeClient: @unchecked Sendable {
    private let axePath = "/opt/homebrew/bin/axe"

    func tap(x: Int, y: Int, simulator: SimulatorInfo) async throws {
        try await runAxe(["tap", "-x", "\(x)", "-y", "\(y)", "--udid", simulator.udid])
    }

    func tap(label: String, simulator: SimulatorInfo) async throws {
        try await runAxe(["tap", "--label", label, "--udid", simulator.udid])
    }

    func type(_ text: String, simulator: SimulatorInfo) async throws {
        try await runAxe(["type", text, "--udid", simulator.udid])
    }

    func gesture(_ gesture: TaskSimulatorGesture, simulator: SimulatorInfo) async throws {
        try await runAxe(["gesture", gesture.rawValue, "--udid", simulator.udid])
    }

    func button(_ button: TaskSimulatorButton, simulator: SimulatorInfo) async throws {
        try await runAxe(["button", button.rawValue, "--udid", simulator.udid])
    }

    func screenshot(simulator: SimulatorInfo) async throws -> Data {
        let outputPath = "/tmp/axe-screenshot-\(UUID().uuidString).png"
        try await runAxe(["screenshot", "--output", outputPath, "--udid", simulator.udid])
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        try? FileManager.default.removeItem(atPath: outputPath)
        return data
    }

    func describeUI(simulator: SimulatorInfo) async throws -> String {
        return try await runAxeWithOutput(["describe-ui", "--udid", simulator.udid])
    }

    private func runAxe(_ arguments: [String]) async throws {
        _ = try await runAxeWithOutput(arguments)
    }

    private func runAxeWithOutput(_ arguments: [String]) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw OrchestratorError.axeFailed(errorMessage)
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

// MARK: - copy-app Client

/// Client for copy-app macOS automation
final class CopyAppClient: @unchecked Sendable {
    private let copyAppPath = "/opt/homebrew/bin/copy-app"

    func click(x: Int, y: Int, simulator: SimulatorInfo) async throws {
        try await runCopyApp(["Simulator", "--click", "\(x),\(y)"])
    }

    func type(_ text: String, simulator: SimulatorInfo) async throws {
        try await runCopyApp(["Simulator", "--type", text])
    }

    func keys(_ combo: String, simulator: SimulatorInfo) async throws {
        try await runCopyApp(["Simulator", "--keys", combo])
    }

    func screenshot(simulator: SimulatorInfo) async throws -> Data {
        let output = try await runCopyAppWithOutput(["Simulator"])
        // Output is the file path
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func runCopyApp(_ arguments: [String]) async throws {
        _ = try await runCopyAppWithOutput(arguments)
    }

    private func runCopyAppWithOutput(_ arguments: [String]) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: copyAppPath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw OrchestratorError.copyAppFailed(errorMessage)
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

// MARK: - Errors

enum OrchestratorError: LocalizedError {
    case invalidResponse
    case cannotParseResponse(String)
    case commandFailed(String)
    case axeFailed(String)
    case copyAppFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from browser"
        case .cannotParseResponse(let raw):
            return "cannot parse response: \(raw.prefix(200))"
        case .commandFailed(let message):
            return "Command failed: \(message)"
        case .axeFailed(let message):
            return "AXe failed: \(message)"
        case .copyAppFailed(let message):
            return "copy-app failed: \(message)"
        }
    }
}
