import Foundation

// MARK: - Automation Task Model

/// A structured automation task that can be executed on simulators
public struct AutomationTask: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let category: TaskCategory
    public let steps: [TaskStep]
    public let icon: String

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        category: TaskCategory,
        steps: [TaskStep],
        icon: String = "play.circle"
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.steps = steps
        self.icon = icon
    }
}

// MARK: - Task Category

public enum TaskCategory: String, CaseIterable, Sendable {
    case navigation = "Navigation"
    case search = "Search"
    case authentication = "Authentication"
    case socialMedia = "Social Media"
    case ecommerce = "E-Commerce"
    case dataExtraction = "Data Extraction"
    case custom = "Custom"

    public var icon: String {
        switch self {
        case .navigation: return "globe"
        case .search: return "magnifyingglass"
        case .authentication: return "lock"
        case .socialMedia: return "person.2"
        case .ecommerce: return "cart"
        case .dataExtraction: return "doc.text"
        case .custom: return "gearshape"
        }
    }
}

// MARK: - Task Step

/// A single step in an automation task
public struct TaskStep: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let action: TaskAction
    public let description: String
    public let waitAfter: TimeInterval
    public let optional: Bool

    public init(
        id: UUID = UUID(),
        action: TaskAction,
        description: String,
        waitAfter: TimeInterval = 0.5,
        optional: Bool = false
    ) {
        self.id = id
        self.action = action
        self.description = description
        self.waitAfter = waitAfter
        self.optional = optional
    }
}

// MARK: - Task Action

/// Actions that can be performed - the orchestrator decides which tool to use
public enum TaskAction: Hashable, Sendable {
    // Navigation
    case goto(url: String)
    case goBack
    case goForward
    case reload

    // Interaction - high level (orchestrator picks tool)
    case click(target: ClickTarget)
    case type(text: String)
    case fill(target: ClickTarget, value: String)
    case scroll(direction: ScrollDirection)
    case tap(x: Int, y: Int)

    // Wait conditions
    case waitForElement(selector: String, timeout: TimeInterval)
    case waitForNavigation(timeout: TimeInterval)
    case waitForTime(seconds: TimeInterval)

    // Data extraction
    case extractText(selector: String, saveAs: String)
    case extractAttribute(selector: String, attribute: String, saveAs: String)
    case screenshot(saveAs: String)

    // Cookies/Session
    case saveCookies(domain: String)
    case loadCookies(domain: String)
    case deleteCookies

    // Conditional - simplified (just check, steps handled separately)
    case checkElementExists(selector: String, saveAs: String)

    // JavaScript
    case evaluate(script: String, saveAs: String?)

    // Hardware buttons (AXe/copy-app)
    case pressButton(button: TaskSimulatorButton)
    case gesture(preset: TaskSimulatorGesture)
}

// MARK: - Click Target

/// Flexible target for clicking - can be selector, coordinates, or label
public enum ClickTarget: Hashable, Sendable {
    case selector(String)
    case coordinates(x: Int, y: Int)
    case label(String)  // Accessibility label
    case text(String)   // Visible text content
}

// MARK: - Scroll Direction

public enum ScrollDirection: String, Hashable, Sendable {
    case up, down, left, right
}

// MARK: - Task Simulator Button (for automation tasks)

public enum TaskSimulatorButton: String, Hashable, Sendable {
    case home
    case lock
    case sideButton = "side-button"
    case siri
    case applePay = "apple-pay"
}

// MARK: - Task Simulator Gesture (for automation tasks)

public enum TaskSimulatorGesture: String, Hashable, Sendable {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down"
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case swipeFromLeftEdge = "swipe-from-left-edge"
    case swipeFromRightEdge = "swipe-from-right-edge"
    case swipeFromTopEdge = "swipe-from-top-edge"
    case swipeFromBottomEdge = "swipe-from-bottom-edge"
}

// MARK: - Task Execution Result

public struct TaskExecutionResult: Identifiable, Sendable {
    public let id: UUID
    public let taskId: UUID
    public let simulatorUDID: String
    public let status: ExecutionStatus
    public let stepResults: [StepResult]
    public let startTime: Date
    public let endTime: Date?
    public let error: String?

    public init(
        id: UUID,
        taskId: UUID,
        simulatorUDID: String,
        status: ExecutionStatus,
        stepResults: [StepResult],
        startTime: Date,
        endTime: Date?,
        error: String?
    ) {
        self.id = id
        self.taskId = taskId
        self.simulatorUDID = simulatorUDID
        self.status = status
        self.stepResults = stepResults
        self.startTime = startTime
        self.endTime = endTime
        self.error = error
    }

    public var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }
}

public enum ExecutionStatus: String, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public struct StepResult: Identifiable, Sendable {
    public let id: UUID
    public let stepId: UUID
    public let toolUsed: AutomationTool
    public let success: Bool
    public let message: String?
    public let duration: TimeInterval
    public let screenshotPath: String?

    public init(
        id: UUID,
        stepId: UUID,
        toolUsed: AutomationTool,
        success: Bool,
        message: String?,
        duration: TimeInterval,
        screenshotPath: String? = nil
    ) {
        self.id = id
        self.stepId = stepId
        self.toolUsed = toolUsed
        self.success = success
        self.message = message
        self.duration = duration
        self.screenshotPath = screenshotPath
    }
}

public enum AutomationTool: String, Sendable {
    case httpBridge = "HTTP Bridge (JS)"
    case axe = "AXe"
    case copyApp = "copy-app"
    case combined = "Combined"
}

// MARK: - Built-in Tasks

public enum BuiltInTasks {

    public static var all: [AutomationTask] {
        [searchAmazon, searchGoogle, browseHackerNews, scrollAndCapture, extractPageData]
    }

    public static var searchAmazon: AutomationTask {
        AutomationTask(
            name: "Search Amazon",
            description: "Navigate to Amazon and search for a product",
            category: .ecommerce,
            steps: [
                TaskStep(action: .goto(url: "https://amazon.com"), description: "Go to Amazon"),
                TaskStep(action: .waitForElement(selector: "input#twotabsearchtextbox", timeout: 10), description: "Wait for search box"),
                TaskStep(action: .click(target: .selector("input#twotabsearchtextbox")), description: "Click search box"),
                TaskStep(action: .type(text: "{{searchQuery}}"), description: "Type search query"),
                TaskStep(action: .click(target: .selector("input#nav-search-submit-button")), description: "Click search button"),
                TaskStep(action: .waitForNavigation(timeout: 10), description: "Wait for results"),
                TaskStep(action: .screenshot(saveAs: "search_results"), description: "Capture results")
            ],
            icon: "cart"
        )
    }

    public static var searchGoogle: AutomationTask {
        AutomationTask(
            name: "Search Google",
            description: "Navigate to Google and perform a search",
            category: .search,
            steps: [
                TaskStep(action: .goto(url: "https://google.com"), description: "Go to Google"),
                TaskStep(action: .waitForElement(selector: "textarea[name='q']", timeout: 10), description: "Wait for search box"),
                TaskStep(action: .fill(target: .selector("textarea[name='q']"), value: "{{searchQuery}}"), description: "Enter search query"),
                TaskStep(action: .evaluate(script: "document.querySelector('form').submit()", saveAs: nil), description: "Submit search"),
                TaskStep(action: .waitForNavigation(timeout: 10), description: "Wait for results"),
                TaskStep(action: .screenshot(saveAs: "google_results"), description: "Capture results")
            ],
            icon: "magnifyingglass"
        )
    }

    public static var browseHackerNews: AutomationTask {
        AutomationTask(
            name: "Browse Hacker News",
            description: "Go to Hacker News and scroll through stories",
            category: .navigation,
            steps: [
                TaskStep(action: .goto(url: "https://news.ycombinator.com"), description: "Go to Hacker News"),
                TaskStep(action: .waitForElement(selector: ".titleline a", timeout: 10), description: "Wait for stories"),
                TaskStep(action: .screenshot(saveAs: "hn_top"), description: "Capture top stories"),
                TaskStep(action: .scroll(direction: .down), description: "Scroll down"),
                TaskStep(action: .waitForTime(seconds: 1), description: "Wait"),
                TaskStep(action: .scroll(direction: .down), description: "Scroll more"),
                TaskStep(action: .screenshot(saveAs: "hn_more"), description: "Capture more stories")
            ],
            icon: "newspaper"
        )
    }

    public static var scrollAndCapture: AutomationTask {
        AutomationTask(
            name: "Scroll & Capture",
            description: "Scroll through a page and capture screenshots",
            category: .dataExtraction,
            steps: [
                TaskStep(action: .screenshot(saveAs: "page_1"), description: "Capture initial view"),
                TaskStep(action: .scroll(direction: .down), description: "Scroll down"),
                TaskStep(action: .waitForTime(seconds: 0.5), description: "Wait"),
                TaskStep(action: .screenshot(saveAs: "page_2"), description: "Capture view 2"),
                TaskStep(action: .scroll(direction: .down), description: "Scroll down"),
                TaskStep(action: .waitForTime(seconds: 0.5), description: "Wait"),
                TaskStep(action: .screenshot(saveAs: "page_3"), description: "Capture view 3"),
                TaskStep(action: .scroll(direction: .down), description: "Scroll down"),
                TaskStep(action: .waitForTime(seconds: 0.5), description: "Wait"),
                TaskStep(action: .screenshot(saveAs: "page_4"), description: "Capture view 4")
            ],
            icon: "camera.viewfinder"
        )
    }

    public static var extractPageData: AutomationTask {
        AutomationTask(
            name: "Extract Page Data",
            description: "Extract text and data from current page",
            category: .dataExtraction,
            steps: [
                TaskStep(action: .evaluate(script: "document.title", saveAs: "page_title"), description: "Get page title"),
                TaskStep(action: .evaluate(script: "window.location.href", saveAs: "page_url"), description: "Get URL"),
                TaskStep(action: .evaluate(script: "document.querySelectorAll('a').length", saveAs: "link_count"), description: "Count links"),
                TaskStep(action: .evaluate(script: "document.querySelectorAll('img').length", saveAs: "image_count"), description: "Count images"),
                TaskStep(action: .screenshot(saveAs: "page_screenshot"), description: "Take screenshot")
            ],
            icon: "doc.text.magnifyingglass"
        )
    }
}
