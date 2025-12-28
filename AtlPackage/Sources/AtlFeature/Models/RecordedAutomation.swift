import Foundation

// MARK: - Recorded Automation

/// A saved automation sequence that can be re-run
public struct RecordedAutomation: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var description: String
    public var steps: [RecordedStep]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        steps: [RecordedStep] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Recorded Step

/// A single recorded automation step
public struct RecordedStep: Identifiable, Codable, Hashable {
    public let id: UUID
    public var action: RecordedAction
    public var description: String
    public var screenshotData: Data?  // Screenshot at time of recording
    public var waitAfter: TimeInterval

    public init(
        id: UUID = UUID(),
        action: RecordedAction,
        description: String,
        screenshotData: Data? = nil,
        waitAfter: TimeInterval = 0.5
    ) {
        self.id = id
        self.action = action
        self.description = description
        self.screenshotData = screenshotData
        self.waitAfter = waitAfter
    }
}

// MARK: - Recorded Action

/// Actions that can be recorded
public enum RecordedAction: Codable, Hashable {
    case tap(x: Int, y: Int, label: String)
    case type(text: String)
    case scroll(direction: String, amount: Int)
    case wait(seconds: TimeInterval)
    case navigate(url: String)
    case pressButton(button: String)
    case gesture(preset: String)

    public var displayName: String {
        switch self {
        case .tap(_, _, let label):
            return "Tap: \(label)"
        case .type(let text):
            return "Type: \"\(text.prefix(20))\(text.count > 20 ? "..." : "")\""
        case .scroll(let direction, _):
            return "Scroll \(direction)"
        case .wait(let seconds):
            return "Wait \(String(format: "%.1f", seconds))s"
        case .navigate(let url):
            return "Go to: \(URL(string: url)?.host ?? url)"
        case .pressButton(let button):
            return "Press \(button)"
        case .gesture(let preset):
            return "Gesture: \(preset)"
        }
    }

    public var icon: String {
        switch self {
        case .tap: return "hand.tap"
        case .type: return "keyboard"
        case .scroll: return "arrow.up.arrow.down"
        case .wait: return "clock"
        case .navigate: return "globe"
        case .pressButton: return "button.horizontal"
        case .gesture: return "hand.draw"
        }
    }
}

// MARK: - Vision Click Request

/// Request to find and click an element using vision AI
public struct VisionClickRequest {
    public let screenshotData: Data
    public let targetDescription: String
    public let simulatorUDID: String

    public init(screenshotData: Data, targetDescription: String, simulatorUDID: String) {
        self.screenshotData = screenshotData
        self.targetDescription = targetDescription
        self.simulatorUDID = simulatorUDID
    }
}

// MARK: - Vision Click Response

/// Response from vision AI with click coordinates
public struct VisionClickResponse {
    public let found: Bool
    public let x: Int
    public let y: Int
    public let confidence: Double
    public let elementDescription: String
    public let reasoning: String

    public init(found: Bool, x: Int, y: Int, confidence: Double, elementDescription: String, reasoning: String) {
        self.found = found
        self.x = x
        self.y = y
        self.confidence = confidence
        self.elementDescription = elementDescription
        self.reasoning = reasoning
    }
}

// MARK: - Automation Storage

/// Manages persistence of recorded automations
@MainActor
public class AutomationStorage: ObservableObject {
    public static let shared = AutomationStorage()

    @Published public var automations: [RecordedAutomation] = []

    private let storageKey = "recorded_automations"

    private init() {
        load()
    }

    public func save(_ automation: RecordedAutomation) {
        if let index = automations.firstIndex(where: { $0.id == automation.id }) {
            var updated = automation
            updated.updatedAt = Date()
            automations[index] = updated
        } else {
            automations.append(automation)
        }
        persist()
    }

    public func delete(_ automation: RecordedAutomation) {
        automations.removeAll { $0.id == automation.id }
        persist()
    }

    public func delete(at offsets: IndexSet) {
        automations.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(automations) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RecordedAutomation].self, from: data) {
            automations = decoded
        }
    }
}
