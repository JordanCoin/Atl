import Foundation

// MARK: - Automation Evaluator

/// Evaluates different automation tool combinations and scores their effectiveness.
/// This helps determine the best approach for different contexts (native UI, WebView, etc.)
@MainActor
@Observable
public class AutomationEvaluator {
    public static let shared = AutomationEvaluator()

    // MARK: - Score Dimensions

    /// Individual metric scores (0.0 to 1.0)
    public struct ScoreMetrics: Codable {
        public var reliability: Double      // Did the action succeed?
        public var accuracy: Double         // Did it hit the right target?
        public var speed: Double            // How fast was execution?
        public var repeatability: Double    // Consistent across multiple runs?
        public var contextAwareness: Double // Correctly detected native vs webview?

        public var overall: Double {
            (reliability * 0.3) + (accuracy * 0.25) + (speed * 0.15) +
            (repeatability * 0.2) + (contextAwareness * 0.1)
        }

        public static var zero: ScoreMetrics {
            ScoreMetrics(reliability: 0, accuracy: 0, speed: 0, repeatability: 0, contextAwareness: 0)
        }
    }

    // MARK: - Tool Strategies

    public enum AutomationTool: String, Codable, CaseIterable {
        case axeTapCoordinates = "axe_tap_xy"
        case axeTapID = "axe_tap_id"
        case axeTapLabel = "axe_tap_label"
        case axeDescribeUI = "axe_describe_ui"
        case axeScreenshot = "axe_screenshot"
        case axeType = "axe_type"

        case copyAppClick = "copyapp_click"
        case copyAppPress = "copyapp_press"
        case copyAppType = "copyapp_type"
        case copyAppKeys = "copyapp_keys"
        case copyAppFind = "copyapp_find"

        case simctlScreenshot = "simctl_screenshot"
        case simctlLaunch = "simctl_launch"
        case simctlTerminate = "simctl_terminate"
        case simctlLog = "simctl_log"

        case javascriptEval = "js_evaluate"
        case javascriptClick = "js_click"

        case httpBridgeCommand = "http_bridge"

        public var category: ToolCategory {
            switch self {
            case .axeTapCoordinates, .axeTapID, .axeTapLabel, .axeDescribeUI, .axeScreenshot, .axeType:
                return .axe
            case .copyAppClick, .copyAppPress, .copyAppType, .copyAppKeys, .copyAppFind:
                return .copyApp
            case .simctlScreenshot, .simctlLaunch, .simctlTerminate, .simctlLog:
                return .simctl
            case .javascriptEval, .javascriptClick:
                return .javascript
            case .httpBridgeCommand:
                return .httpBridge
            }
        }
    }

    public enum ToolCategory: String, Codable {
        case axe = "axe"
        case copyApp = "copy-app"
        case simctl = "simctl"
        case javascript = "javascript"
        case httpBridge = "http_bridge"
    }

    public enum TargetContext: String, Codable {
        case iOSSimulatorNative = "ios_native"
        case iOSSimulatorWebView = "ios_webview"
        case macOSNative = "macos_native"
        case macOSWebView = "macos_webview"
        case atlBrowser = "atl_browser"
    }

    // MARK: - Evaluation Result

    public struct EvaluationResult: Identifiable, Codable {
        public let id: UUID
        public let tool: AutomationTool
        public let context: TargetContext
        public let action: String
        public let succeeded: Bool
        public let durationMs: Int
        public let scores: ScoreMetrics
        public let errorMessage: String?
        public let timestamp: Date
        public let metadata: [String: String]

        public init(
            tool: AutomationTool,
            context: TargetContext,
            action: String,
            succeeded: Bool,
            durationMs: Int,
            scores: ScoreMetrics,
            errorMessage: String? = nil,
            metadata: [String: String] = [:]
        ) {
            self.id = UUID()
            self.tool = tool
            self.context = context
            self.action = action
            self.succeeded = succeeded
            self.durationMs = durationMs
            self.scores = scores
            self.errorMessage = errorMessage
            self.timestamp = Date()
            self.metadata = metadata
        }
    }

    // MARK: - State

    public var evaluationHistory: [EvaluationResult] = []
    public var isEvaluating = false

    /// Aggregated scores by tool and context
    public var toolScores: [String: ScoreMetrics] = [:]

    private init() {
        loadHistory()
    }

    // MARK: - Run Evaluation

    /// Evaluate a tap action using multiple tools and compare results
    public func evaluateTapStrategies(
        context: TargetContext,
        udid: String?,
        appName: String?,
        x: Int,
        y: Int,
        accessibilityID: String?,
        label: String?,
        expectedOutcome: @escaping () async -> Bool
    ) async -> [EvaluationResult] {
        isEvaluating = true
        defer { isEvaluating = false }

        var results: [EvaluationResult] = []

        // Determine which tools to test based on context
        let toolsToTest: [AutomationTool]
        switch context {
        case .iOSSimulatorNative:
            toolsToTest = [.axeTapCoordinates, .axeTapID, .axeTapLabel]
        case .iOSSimulatorWebView:
            toolsToTest = [.javascriptClick]
        case .macOSNative:
            toolsToTest = [.copyAppClick, .copyAppPress]
        case .macOSWebView:
            toolsToTest = [.copyAppClick, .javascriptClick]
        case .atlBrowser:
            toolsToTest = [.httpBridgeCommand, .javascriptClick]
        }

        for tool in toolsToTest {
            let startTime = Date()
            var succeeded = false

            switch tool {
            case .axeTapCoordinates:
                if let udid = udid {
                    succeeded = await executeAxeTapCoordinates(udid: udid, x: x, y: y)
                }
            case .axeTapID:
                if let udid = udid, let id = accessibilityID {
                    succeeded = await executeAxeTapID(udid: udid, accessibilityID: id)
                }
            case .axeTapLabel:
                if let udid = udid, let lbl = label {
                    succeeded = await executeAxeTapLabel(udid: udid, label: lbl)
                }
            case .copyAppClick:
                if let app = appName {
                    succeeded = await executeCopyAppClick(appName: app, x: x, y: y)
                }
            case .copyAppPress:
                if let app = appName, let lbl = label {
                    succeeded = await executeCopyAppPress(appName: app, buttonName: lbl)
                }
            default:
                continue
            }

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            // Verify outcome
            let outcomeCorrect = await expectedOutcome()

            // Calculate scores
            let scores = ScoreMetrics(
                reliability: succeeded ? 1.0 : 0.0,
                accuracy: outcomeCorrect ? 1.0 : 0.0,
                speed: calculateSpeedScore(durationMs: durationMs),
                repeatability: 1.0, // Would need multiple runs to calculate
                contextAwareness: 1.0 // We're testing in known context
            )

            let result = EvaluationResult(
                tool: tool,
                context: context,
                action: "tap",
                succeeded: succeeded && outcomeCorrect,
                durationMs: durationMs,
                scores: scores,
                errorMessage: nil,
                metadata: [
                    "x": "\(x)",
                    "y": "\(y)",
                    "accessibilityID": accessibilityID ?? "",
                    "label": label ?? ""
                ]
            )

            results.append(result)
            evaluationHistory.append(result)
        }

        updateAggregatedScores()
        saveHistory()

        return results
    }

    /// Quick evaluation of a single tool action
    public func evaluateAction(
        tool: AutomationTool,
        context: TargetContext,
        action: String,
        execute: @escaping () async -> Bool
    ) async -> EvaluationResult {
        let startTime = Date()
        let succeeded = await execute()
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        let scores = ScoreMetrics(
            reliability: succeeded ? 1.0 : 0.0,
            accuracy: succeeded ? 1.0 : 0.0,
            speed: calculateSpeedScore(durationMs: durationMs),
            repeatability: 1.0,
            contextAwareness: 1.0
        )

        let result = EvaluationResult(
            tool: tool,
            context: context,
            action: action,
            succeeded: succeeded,
            durationMs: durationMs,
            scores: scores
        )

        evaluationHistory.append(result)
        updateAggregatedScores()
        saveHistory()

        return result
    }

    // MARK: - Tool Execution (via ToolExecutor)

    private func executeAxeTapCoordinates(udid: String, x: Int, y: Int) async -> Bool {
        await ToolExecutor.Axe.tap(udid: udid, x: x, y: y).success
    }

    private func executeAxeTapID(udid: String, accessibilityID: String) async -> Bool {
        await ToolExecutor.Axe.tap(udid: udid, id: accessibilityID).success
    }

    private func executeAxeTapLabel(udid: String, label: String) async -> Bool {
        await ToolExecutor.Axe.tap(udid: udid, label: label).success
    }

    private func executeCopyAppClick(appName: String, x: Int, y: Int) async -> Bool {
        await ToolExecutor.CopyApp.click(appName: appName, x: x, y: y).success
    }

    private func executeCopyAppPress(appName: String, buttonName: String) async -> Bool {
        await ToolExecutor.CopyApp.press(appName: appName, buttonName: buttonName).success
    }

    // MARK: - Scoring Helpers

    private func calculateSpeedScore(durationMs: Int) -> Double {
        // Under 100ms = perfect, degrades to 0 at 5000ms
        let maxMs = 5000.0
        let score = 1.0 - (Double(durationMs) / maxMs)
        return max(0, min(1, score))
    }

    private func updateAggregatedScores() {
        var scoresByTool: [String: [ScoreMetrics]] = [:]

        for result in evaluationHistory {
            let key = "\(result.tool.rawValue)_\(result.context.rawValue)"
            scoresByTool[key, default: []].append(result.scores)
        }

        for (key, scores) in scoresByTool {
            let count = Double(scores.count)
            let aggregated = ScoreMetrics(
                reliability: scores.map(\.reliability).reduce(0, +) / count,
                accuracy: scores.map(\.accuracy).reduce(0, +) / count,
                speed: scores.map(\.speed).reduce(0, +) / count,
                repeatability: scores.map(\.repeatability).reduce(0, +) / count,
                contextAwareness: scores.map(\.contextAwareness).reduce(0, +) / count
            )
            toolScores[key] = aggregated
        }
    }

    // MARK: - Best Tool Recommendation

    /// Get the recommended tool for a given context and action
    public func recommendTool(for context: TargetContext, action: String) -> AutomationTool? {
        let relevantScores = toolScores.filter { key, _ in
            key.contains(context.rawValue)
        }

        guard !relevantScores.isEmpty else {
            // No data, return default
            return defaultTool(for: context, action: action)
        }

        let best = relevantScores.max { $0.value.overall < $1.value.overall }
        if let bestKey = best?.key,
           let toolRaw = bestKey.split(separator: "_").first,
           let tool = AutomationTool(rawValue: String(toolRaw)) {
            return tool
        }

        return defaultTool(for: context, action: action)
    }

    private func defaultTool(for context: TargetContext, action: String) -> AutomationTool {
        switch context {
        case .iOSSimulatorNative:
            return action == "tap" ? .axeTapID : .axeType
        case .iOSSimulatorWebView:
            return .javascriptClick
        case .macOSNative:
            return action == "tap" ? .copyAppPress : .copyAppType
        case .macOSWebView:
            return .copyAppClick
        case .atlBrowser:
            return .httpBridgeCommand
        }
    }

    // MARK: - Persistence

    private let historyKey = "automation_evaluation_history"
    private let scoresKey = "automation_tool_scores"

    private func saveHistory() {
        // Only keep last 1000 results
        let toSave = Array(evaluationHistory.suffix(1000))
        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
        if let scoresData = try? JSONEncoder().encode(toolScores) {
            UserDefaults.standard.set(scoresData, forKey: scoresKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let history = try? JSONDecoder().decode([EvaluationResult].self, from: data) {
            evaluationHistory = history
        }
        if let data = UserDefaults.standard.data(forKey: scoresKey),
           let scores = try? JSONDecoder().decode([String: ScoreMetrics].self, from: data) {
            toolScores = scores
        }
    }

    /// Clear all evaluation history
    public func clearHistory() {
        evaluationHistory = []
        toolScores = [:]
        UserDefaults.standard.removeObject(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: scoresKey)
    }

    // MARK: - Reports

    /// Generate a summary report of tool effectiveness
    public func generateReport() -> String {
        var report = "# Automation Tool Evaluation Report\n\n"
        report += "Generated: \(Date())\n"
        report += "Total evaluations: \(evaluationHistory.count)\n\n"

        report += "## Tool Scores by Context\n\n"
        report += "| Tool | Context | Reliability | Accuracy | Speed | Overall |\n"
        report += "|------|---------|-------------|----------|-------|--------|\n"

        for (key, scores) in toolScores.sorted(by: { $0.value.overall > $1.value.overall }) {
            let parts = key.split(separator: "_")
            let tool = parts.first ?? "?"
            let context = parts.dropFirst().joined(separator: "_")

            report += "| \(tool) | \(context) | "
            report += String(format: "%.1f%% | ", scores.reliability * 100)
            report += String(format: "%.1f%% | ", scores.accuracy * 100)
            report += String(format: "%.1f%% | ", scores.speed * 100)
            report += String(format: "%.1f%% |\n", scores.overall * 100)
        }

        report += "\n## Recommendations\n\n"
        for context in TargetContext.allCases {
            if let tool = recommendTool(for: context, action: "tap") {
                report += "- **\(context.rawValue)**: Use `\(tool.rawValue)`\n"
            }
        }

        return report
    }
}

extension AutomationEvaluator.TargetContext: CaseIterable {}
