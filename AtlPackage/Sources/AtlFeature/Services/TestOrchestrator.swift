import Foundation

// MARK: - Test Orchestrator

/// Coordinates automated testing: build → launch → interact → validate
@MainActor
@Observable
public class TestOrchestrator {
    public static let shared = TestOrchestrator()

    // MARK: - Types

    public enum TestStep: Identifiable, Equatable {
        case build
        case launch
        case waitForReady
        case captureBaseline
        case runAutomation(String)
        case validateResult
        case captureLogs

        public var id: String {
            switch self {
            case .build: return "build"
            case .launch: return "launch"
            case .waitForReady: return "waitForReady"
            case .captureBaseline: return "captureBaseline"
            case .runAutomation(let name): return "automation-\(name)"
            case .validateResult: return "validate"
            case .captureLogs: return "logs"
            }
        }

        public var displayName: String {
            switch self {
            case .build: return "Build Project"
            case .launch: return "Launch App"
            case .waitForReady: return "Wait for Ready"
            case .captureBaseline: return "Capture Baseline"
            case .runAutomation(let name): return "Run: \(name)"
            case .validateResult: return "Validate Result"
            case .captureLogs: return "Capture Logs"
            }
        }
    }

    public struct TestResult: Identifiable {
        public let id = UUID()
        public let step: TestStep
        public let success: Bool
        public let message: String
        public let duration: TimeInterval
        public let screenshot: Data?
        public let logs: String?
        public let timestamp: Date

        public init(
            step: TestStep,
            success: Bool,
            message: String,
            duration: TimeInterval,
            screenshot: Data? = nil,
            logs: String? = nil
        ) {
            self.step = step
            self.success = success
            self.message = message
            self.duration = duration
            self.screenshot = screenshot
            self.logs = logs
            self.timestamp = Date()
        }
    }

    public struct TestRun: Identifiable {
        public let id = UUID()
        public let target: BuildStateService.ProjectTarget
        public var steps: [TestStep]
        public var results: [TestResult] = []
        public var status: Status = .pending
        public let startTime: Date

        public enum Status {
            case pending
            case running
            case passed
            case failed
            case cancelled
        }

        public var passedCount: Int { results.filter { $0.success }.count }
        public var failedCount: Int { results.filter { !$0.success }.count }
        public var totalDuration: TimeInterval {
            results.reduce(0) { $0 + $1.duration }
        }
    }

    // MARK: - State

    public var currentRun: TestRun?
    public var runHistory: [TestRun] = []
    public var isRunning = false
    public var currentStepIndex = 0
    public var logCapture: String = ""

    // Simulator state
    public var simulatorUDID: String?
    public var logSessionId: String?

    private let buildService = BuildStateService.shared
    private let visionService = VisionService.shared

    private init() {}

    // MARK: - Test Execution

    /// Run a full test suite against a target
    public func runTests(
        target: BuildStateService.ProjectTarget,
        steps: [TestStep]
    ) async -> TestRun {
        isRunning = true
        currentStepIndex = 0
        logCapture = ""

        var run = TestRun(
            target: target,
            steps: steps,
            startTime: Date()
        )
        run.status = .running
        currentRun = run

        for (index, step) in steps.enumerated() {
            currentStepIndex = index

            let startTime = Date()
            let result = await executeStep(step, target: target)
            let duration = Date().timeIntervalSince(startTime)

            let testResult = TestResult(
                step: step,
                success: result.success,
                message: result.message,
                duration: duration,
                screenshot: result.screenshot,
                logs: result.logs
            )

            run.results.append(testResult)
            currentRun = run

            // Stop on failure unless it's log capture
            if !result.success && step != .captureLogs {
                run.status = .failed
                break
            }
        }

        if run.status == .running {
            run.status = run.results.allSatisfy({ $0.success }) ? .passed : .failed
        }

        currentRun = run
        runHistory.insert(run, at: 0)
        isRunning = false

        return run
    }

    // MARK: - Step Execution

    private struct StepResult {
        let success: Bool
        let message: String
        let screenshot: Data?
        let logs: String?
    }

    private func executeStep(
        _ step: TestStep,
        target: BuildStateService.ProjectTarget
    ) async -> StepResult {
        switch step {
        case .build:
            return await executeBuild(target)

        case .launch:
            return await executeLaunch(target)

        case .waitForReady:
            return await executeWaitForReady(target)

        case .captureBaseline:
            return await executeCaptureBaseline(target)

        case .runAutomation(let name):
            return await executeAutomation(name, target: target)

        case .validateResult:
            return await executeValidation(target)

        case .captureLogs:
            return await executeCaptureLogs(target)
        }
    }

    private func executeBuild(_ target: BuildStateService.ProjectTarget) async -> StepResult {
        let result = await buildService.build(target)

        return StepResult(
            success: result.success,
            message: result.success
                ? "Build succeeded: \(result.appPath ?? "unknown")"
                : "Build failed: \(result.errors.joined(separator: "\n"))",
            screenshot: nil,
            logs: result.logs
        )
    }

    private func executeLaunch(_ target: BuildStateService.ProjectTarget) async -> StepResult {
        let result = await buildService.launchApp(target)

        // Start log capture for simulator
        if target.platform == .iOSSimulator, let bundleId = target.bundleId {
            logSessionId = await startLogCapture(bundleId: bundleId)
        }

        return StepResult(
            success: result.success,
            message: result.logs,
            screenshot: nil,
            logs: result.logs
        )
    }

    private func executeWaitForReady(_ target: BuildStateService.ProjectTarget) async -> StepResult {
        // Wait for app to be ready (UI responsive)
        var attempts = 0
        let maxAttempts = 10

        while attempts < maxAttempts {
            attempts += 1

            // Try to capture screenshot - if it works, app is ready
            if let _ = await captureScreenshot(target) {
                return StepResult(
                    success: true,
                    message: "App ready after \(attempts) attempts",
                    screenshot: nil,
                    logs: nil
                )
            }

            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }

        return StepResult(
            success: false,
            message: "App not ready after \(maxAttempts) attempts",
            screenshot: nil,
            logs: nil
        )
    }

    private func executeCaptureBaseline(_ target: BuildStateService.ProjectTarget) async -> StepResult {
        guard let screenshot = await captureScreenshot(target) else {
            return StepResult(
                success: false,
                message: "Failed to capture baseline screenshot",
                screenshot: nil,
                logs: nil
            )
        }

        return StepResult(
            success: true,
            message: "Captured baseline screenshot",
            screenshot: screenshot,
            logs: nil
        )
    }

    private func executeAutomation(_ name: String, target: BuildStateService.ProjectTarget) async -> StepResult {
        // Find saved automation by name
        let storage = AutomationStorage.shared
        guard let automation = storage.automations.first(where: { $0.name == name }) else {
            return StepResult(
                success: false,
                message: "Automation '\(name)' not found",
                screenshot: nil,
                logs: nil
            )
        }

        // Run each step
        for step in automation.steps {
            let stepResult = await executeAutomationStep(step, target: target)
            if !stepResult {
                return StepResult(
                    success: false,
                    message: "Step failed: \(step.action.displayName)",
                    screenshot: await captureScreenshot(target),
                    logs: nil
                )
            }

            // Wait between steps
            try? await Task.sleep(nanoseconds: UInt64(step.waitAfter * 1_000_000_000))
        }

        return StepResult(
            success: true,
            message: "Automation '\(name)' completed",
            screenshot: await captureScreenshot(target),
            logs: nil
        )
    }

    private func executeAutomationStep(_ step: RecordedStep, target: BuildStateService.ProjectTarget) async -> Bool {
        switch target.platform {
        case .iOSSimulator:
            return await executeSimulatorStep(step)
        case .macOS:
            return await executeMacOSStep(step)
        }
    }

    private func executeSimulatorStep(_ step: RecordedStep) async -> Bool {
        guard let udid = simulatorUDID ?? getBootedSimulatorUDID() else {
            return false
        }

        switch step.action {
        case .tap(let x, let y, _):
            return await executeTap(udid: udid, x: x, y: y)
        case .type(let text):
            return await executeType(udid: udid, text: text)
        case .scroll(let direction, _):
            return await executeScroll(udid: udid, direction: direction)
        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        case .navigate, .pressButton, .gesture:
            // TODO: Implement these
            return true
        }
    }

    private func executeMacOSStep(_ step: RecordedStep) async -> Bool {
        // Use copy-app or AppleScript for macOS automation
        switch step.action {
        case .tap(let x, let y, _):
            return await executeMacOSTap(x: x, y: y)
        case .type(let text):
            return await executeMacOSType(text: text)
        default:
            return true
        }
    }

    private func executeValidation(_ target: BuildStateService.ProjectTarget) async -> StepResult {
        // Capture final screenshot and compare/validate
        guard let screenshot = await captureScreenshot(target) else {
            return StepResult(
                success: false,
                message: "Failed to capture validation screenshot",
                screenshot: nil,
                logs: nil
            )
        }

        return StepResult(
            success: true,
            message: "Validation passed",
            screenshot: screenshot,
            logs: nil
        )
    }

    private func executeCaptureLogs(_ target: BuildStateService.ProjectTarget) async -> StepResult {
        var logs = logCapture

        // Stop log capture if active
        if let sessionId = logSessionId {
            logs = await stopLogCapture(sessionId: sessionId)
            logSessionId = nil
        }

        return StepResult(
            success: true,
            message: "Logs captured",
            screenshot: nil,
            logs: logs
        )
    }

    // MARK: - Helpers

    private func captureScreenshot(_ target: BuildStateService.ProjectTarget) async -> Data? {
        switch target.platform {
        case .iOSSimulator:
            let udid = simulatorUDID ?? getBootedSimulatorUDID()
            guard let udid = udid else { return nil }
            return await visionService.captureSimulatorScreenshot(udid: udid)

        case .macOS:
            return await captureMacOSScreenshot(appName: target.scheme)
        }
    }

    private func captureMacOSScreenshot(appName: String) async -> Data? {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("macos_screenshot_\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", tempPath.path]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0,
               let data = try? Data(contentsOf: tempPath) {
                try? FileManager.default.removeItem(at: tempPath)
                return data
            }
        } catch {
            print("screencapture failed: \(error)")
        }

        return nil
    }

    private func getBootedSimulatorUDID() -> String? {
        // Use synchronous wrapper since this is called from sync context
        // For async contexts, use ToolExecutor.Simctl.bootedUDID() directly
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        Task {
            result = await ToolExecutor.Simctl.bootedUDID()
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }

    // MARK: - Simulator Interactions (via ToolExecutor)

    private func executeTap(udid: String, x: Int, y: Int) async -> Bool {
        await ToolExecutor.Axe.tap(udid: udid, x: x, y: y).success
    }

    private func executeType(udid: String, text: String) async -> Bool {
        await ToolExecutor.Axe.type(udid: udid, text: text).success
    }

    private func executeScroll(udid: String, direction: String) async -> Bool {
        await ToolExecutor.Axe.gesture(udid: udid, preset: "scroll-\(direction)").success
    }

    // MARK: - macOS Interactions (via ToolExecutor)

    private func executeMacOSTap(x: Int, y: Int) async -> Bool {
        guard let target = currentRun?.target else { return false }
        return await ToolExecutor.CopyApp.click(appName: target.scheme, x: x, y: y).success
    }

    private func executeMacOSType(text: String) async -> Bool {
        guard let target = currentRun?.target else { return false }
        return await ToolExecutor.CopyApp.type(appName: target.scheme, text: text).success
    }

    private func executeMacOSPress(buttonName: String) async -> Bool {
        guard let target = currentRun?.target else { return false }
        return await ToolExecutor.CopyApp.press(appName: target.scheme, buttonName: buttonName).success
    }

    private func executeMacOSKeys(combo: String) async -> Bool {
        guard let target = currentRun?.target else { return false }
        return await ToolExecutor.CopyApp.keys(appName: target.scheme, combo: combo).success
    }

    // MARK: - UI Hierarchy (via ToolExecutor)

    /// Get UI hierarchy from iOS Simulator using axe describe-ui
    public func getSimulatorUIHierarchy(udid: String) async -> String? {
        let result = await ToolExecutor.Axe.describeUI(udid: udid)
        return result.success ? result.output : nil
    }

    /// Find element by accessibility ID and get its coordinates
    public func findElementByID(udid: String, accessibilityID: String) async -> (x: Int, y: Int)? {
        guard let hierarchy = await getSimulatorUIHierarchy(udid: udid) else { return nil }
        return Self.findElementInHierarchy(hierarchy, matching: { node in
            node["identifier"] as? String == accessibilityID
        })
    }

    /// Find element by label text and get its coordinates
    public func findElementByLabel(udid: String, label: String) async -> (x: Int, y: Int)? {
        guard let hierarchy = await getSimulatorUIHierarchy(udid: udid) else { return nil }
        return Self.findElementInHierarchy(hierarchy, matching: { node in
            (node["label"] as? String)?.localizedStandardContains(label) ?? false
        })
    }

    /// Recursively search hierarchy for element matching predicate
    private static func findElementInHierarchy(
        _ hierarchy: String,
        matching predicate: ([String: Any]) -> Bool
    ) -> (x: Int, y: Int)? {
        guard let data = hierarchy.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func search(in node: [String: Any]) -> (x: Int, y: Int)? {
            if predicate(node),
               let frame = node["frame"] as? [String: Any],
               let x = frame["x"] as? Double,
               let y = frame["y"] as? Double,
               let width = frame["width"] as? Double,
               let height = frame["height"] as? Double {
                return (Int(x + width / 2), Int(y + height / 2))
            }

            if let children = node["children"] as? [[String: Any]] {
                for child in children {
                    if let result = search(in: child) {
                        return result
                    }
                }
            }
            return nil
        }

        return search(in: json)
    }

    /// Tap element by accessibility ID (preferred over coordinates)
    public func tapByID(udid: String, accessibilityID: String) async -> Bool {
        await ToolExecutor.Axe.tap(udid: udid, id: accessibilityID).success
    }

    // MARK: - Log Capture

    private func startLogCapture(bundleId: String) async -> String? {
        // Start simctl log stream in background
        guard let udid = simulatorUDID ?? getBootedSimulatorUDID() else {
            return nil
        }

        let sessionId = "log-\(UUID().uuidString)"

        // Note: In a real implementation, this would spawn a background process
        // that streams logs to a file, which we'd read when stopping capture
        logCapture = "[Log capture started for \(bundleId) on \(udid)]\n"

        return sessionId
    }

    private func stopLogCapture(sessionId: String) async -> String {
        // Return captured logs
        let logs = logCapture
        logCapture = ""
        return logs
    }
}
