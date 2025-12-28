import Foundation
import AppKit

// MARK: - Playwright Controller

/// Controls web automation in iOS Simulators via a custom browser app
/// Similar to Playwright but for iOS Simulator WebViews
public actor PlaywrightController {
    public static let shared = PlaywrightController()

    // MARK: - State

    private var activeSimulatorUDID: String?
    private var browserPort: Int = 9222
    private var isConnected: Bool = false
    private var pendingRequests: [String: CheckedContinuation<CommandResponse, Error>] = [:]

    // Cookie storage directory
    private let cookieStorageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let atlDir = appSupport.appendingPathComponent("Atl/Cookies", isDirectory: true)
        try? FileManager.default.createDirectory(at: atlDir, withIntermediateDirectories: true)
        return atlDir
    }()

    private init() {}

    // MARK: - Lifecycle

    /// Launch the browser in a simulator
    /// - Parameters:
    ///   - simulatorUDID: Specific simulator UDID or nil for default
    ///   - headless: Not supported on iOS, ignored
    public func launch(simulator simulatorUDID: String? = nil) async throws {
        let udid: String

        if let specific = simulatorUDID {
            udid = specific
        } else {
            // Find a booted simulator or boot one
            let simulators = await SimulatorManager.shared.fetchSimulators()
            if let booted = simulators.first(where: { $0.state.lowercased() == "booted" }) {
                udid = booted.udid
            } else if let first = simulators.first {
                let success = await SimulatorManager.shared.bootSimulator(udid: first.udid)
                guard success else {
                    throw PlaywrightError.simulatorBootFailed
                }
                udid = first.udid
                // Wait for boot
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                throw PlaywrightError.noSimulatorsAvailable
            }
        }

        activeSimulatorUDID = udid

        // Open Simulator app
        await SimulatorManager.shared.openSimulatorApp(udid: udid)

        // Install and launch AtlBrowser app
        try await installBrowserApp(udid: udid)
        try await launchBrowserApp(udid: udid)

        // Wait for browser to start its HTTP server
        try await waitForBrowserConnection()

        isConnected = true
    }

    /// Close the browser and clean up
    public func close() async throws {
        guard let udid = activeSimulatorUDID else { return }

        // Terminate the browser app
        try await terminateBrowserApp(udid: udid)

        isConnected = false
        activeSimulatorUDID = nil
    }

    // MARK: - Navigation

    /// Navigate to a URL
    public func goto(_ url: String) async throws {
        let response = try await sendCommand(.goto(url: url))
        guard response.success else {
            throw PlaywrightError.navigationFailed(response.error ?? "Unknown error")
        }
    }

    /// Reload the current page
    public func reload() async throws {
        let response = try await sendCommand(.reload)
        guard response.success else {
            throw PlaywrightError.commandFailed("reload", response.error)
        }
    }

    /// Go back in history
    public func goBack() async throws {
        let response = try await sendCommand(.goBack)
        guard response.success else {
            throw PlaywrightError.commandFailed("goBack", response.error)
        }
    }

    /// Go forward in history
    public func goForward() async throws {
        let response = try await sendCommand(.goForward)
        guard response.success else {
            throw PlaywrightError.commandFailed("goForward", response.error)
        }
    }

    /// Get current URL
    public func url() async throws -> String {
        let response = try await sendCommand(.getURL)
        guard response.success, let url = response.result?["url"] as? String else {
            throw PlaywrightError.commandFailed("url", response.error)
        }
        return url
    }

    /// Get page title
    public func title() async throws -> String {
        let response = try await sendCommand(.getTitle)
        guard response.success, let title = response.result?["title"] as? String else {
            throw PlaywrightError.commandFailed("title", response.error)
        }
        return title
    }

    // MARK: - Interactions

    /// Click an element by CSS selector
    public func click(_ selector: String) async throws {
        let response = try await sendCommand(.click(selector: selector))
        guard response.success else {
            throw PlaywrightError.elementNotFound(selector)
        }
    }

    /// Double-click an element
    public func doubleClick(_ selector: String) async throws {
        let response = try await sendCommand(.doubleClick(selector: selector))
        guard response.success else {
            throw PlaywrightError.elementNotFound(selector)
        }
    }

    /// Type text into the focused element
    public func type(_ text: String, delay: TimeInterval = 0) async throws {
        let response = try await sendCommand(.type(text: text, delay: delay))
        guard response.success else {
            throw PlaywrightError.commandFailed("type", response.error)
        }
    }

    /// Fill a form field (clears first, then types)
    public func fill(_ selector: String, value: String) async throws {
        let response = try await sendCommand(.fill(selector: selector, value: value))
        guard response.success else {
            throw PlaywrightError.elementNotFound(selector)
        }
    }

    /// Press a key
    public func press(_ key: String) async throws {
        let response = try await sendCommand(.press(key: key))
        guard response.success else {
            throw PlaywrightError.commandFailed("press", response.error)
        }
    }

    /// Hover over an element
    public func hover(_ selector: String) async throws {
        let response = try await sendCommand(.hover(selector: selector))
        guard response.success else {
            throw PlaywrightError.elementNotFound(selector)
        }
    }

    /// Scroll element into view
    public func scrollIntoView(_ selector: String) async throws {
        let response = try await sendCommand(.scrollIntoView(selector: selector))
        guard response.success else {
            throw PlaywrightError.elementNotFound(selector)
        }
    }

    // MARK: - Selectors

    /// Query for a single element
    public func querySelector(_ selector: String) async throws -> Element? {
        let response = try await sendCommand(.querySelector(selector: selector))
        guard response.success else {
            return nil
        }

        if let elementData = response.result?["element"] as? [String: Any] {
            return Element(from: elementData)
        }
        return nil
    }

    /// Query for multiple elements
    public func querySelectorAll(_ selector: String) async throws -> [Element] {
        let response = try await sendCommand(.querySelectorAll(selector: selector))
        guard response.success,
              let elementsData = response.result?["elements"] as? [[String: Any]] else {
            return []
        }

        return elementsData.compactMap { Element(from: $0) }
    }

    /// Wait for an element to appear
    public func waitForSelector(_ selector: String, timeout: TimeInterval = 30) async throws {
        let response = try await sendCommand(.waitForSelector(selector: selector, timeout: timeout))
        guard response.success else {
            throw PlaywrightError.timeout("Waiting for selector: \(selector)")
        }
    }

    /// Wait for navigation to complete
    public func waitForNavigation(timeout: TimeInterval = 30) async throws {
        let response = try await sendCommand(.waitForNavigation(timeout: timeout))
        guard response.success else {
            throw PlaywrightError.timeout("Waiting for navigation")
        }
    }

    // MARK: - JavaScript Execution

    /// Evaluate JavaScript and return result
    public func evaluate<T>(_ script: String) async throws -> T {
        let response = try await sendCommand(.evaluate(script: script))
        guard response.success else {
            throw PlaywrightError.javascriptError(response.error ?? "Unknown error")
        }

        guard let result = response.result?["value"] as? T else {
            throw PlaywrightError.javascriptError("Could not convert result to expected type")
        }
        return result
    }

    /// Evaluate JavaScript without return value
    public func evaluate(_ script: String) async throws {
        let response = try await sendCommand(.evaluate(script: script))
        guard response.success else {
            throw PlaywrightError.javascriptError(response.error ?? "Unknown error")
        }
    }

    // MARK: - Screenshots

    /// Take a screenshot of the viewport
    public func screenshot() async throws -> Data {
        let response = try await sendCommand(.screenshot(fullPage: false, selector: nil))
        guard response.success,
              let base64 = response.result?["data"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw PlaywrightError.screenshotFailed
        }
        return data
    }

    /// Take a screenshot of a specific element
    public func screenshot(selector: String) async throws -> Data {
        let response = try await sendCommand(.screenshot(fullPage: false, selector: selector))
        guard response.success,
              let base64 = response.result?["data"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw PlaywrightError.screenshotFailed
        }
        return data
    }

    /// Take a full-page screenshot
    public func screenshotFullPage() async throws -> Data {
        let response = try await sendCommand(.screenshot(fullPage: true, selector: nil))
        guard response.success,
              let base64 = response.result?["data"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw PlaywrightError.screenshotFailed
        }
        return data
    }

    /// Take a screenshot of the simulator using AXe
    public func screenshotSimulator(output: URL? = nil) async throws -> Data {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        let outputPath = output ?? FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-\(UUID().uuidString).png")

        try await runAxe(["screenshot", "--output", outputPath.path, "--udid", udid])

        let data = try Data(contentsOf: outputPath)

        // Clean up temp file if we created it
        if output == nil {
            try? FileManager.default.removeItem(at: outputPath)
        }

        return data
    }

    // MARK: - Simulator-Level Automation (AXe)

    /// Tap at specific coordinates on the simulator screen
    public func simulatorTap(x: Int, y: Int, preDelay: Double? = nil, postDelay: Double? = nil) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        var args = ["tap", "-x", String(x), "-y", String(y), "--udid", udid]
        if let preDelay = preDelay {
            args += ["--pre-delay", String(preDelay)]
        }
        if let postDelay = postDelay {
            args += ["--post-delay", String(postDelay)]
        }

        try await runAxe(args)
    }

    /// Tap on an element by accessibility ID
    public func simulatorTap(accessibilityId: String) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        try await runAxe(["tap", "--id", accessibilityId, "--udid", udid])
    }

    /// Tap on an element by accessibility label
    public func simulatorTap(label: String) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        try await runAxe(["tap", "--label", label, "--udid", udid])
    }

    /// Type text using the simulator keyboard
    public func simulatorType(_ text: String) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        try await runAxe(["type", text, "--udid", udid])
    }

    /// Swipe gesture on the simulator
    public func simulatorSwipe(
        startX: Int, startY: Int,
        endX: Int, endY: Int,
        duration: Double? = nil
    ) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        var args = [
            "swipe",
            "--start-x", String(startX),
            "--start-y", String(startY),
            "--end-x", String(endX),
            "--end-y", String(endY),
            "--udid", udid
        ]
        if let duration = duration {
            args += ["--duration", String(duration)]
        }

        try await runAxe(args)
    }

    /// Preset gesture (scroll, edge swipes)
    public func simulatorGesture(_ gesture: SimulatorGesture) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        try await runAxe(["gesture", gesture.rawValue, "--udid", udid])
    }

    /// Press a hardware button
    public func simulatorButton(_ button: SimulatorButton, duration: Double? = nil) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        var args = ["button", button.rawValue, "--udid", udid]
        if let duration = duration {
            args += ["--duration", String(duration)]
        }

        try await runAxe(args)
    }

    /// Press a key by keycode
    public func simulatorKey(_ keycode: Int, duration: Double? = nil) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        var args = ["key", String(keycode), "--udid", udid]
        if let duration = duration {
            args += ["--duration", String(duration)]
        }

        try await runAxe(args)
    }

    /// Get UI hierarchy via accessibility APIs
    public func describeUI(at point: (x: Int, y: Int)? = nil) async throws -> String {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        var args = ["describe-ui", "--udid", udid]
        if let point = point {
            args += ["--point", "\(point.x),\(point.y)"]
        }

        return try await runAxeWithOutput(args)
    }

    /// List available simulators
    public func listSimulators() async throws -> String {
        return try await runAxeWithOutput(["list-simulators"])
    }

    // MARK: - AXe Runner

    private static let axePath = "/opt/homebrew/bin/axe"

    @discardableResult
    private func runAxe(_ arguments: [String]) async throws -> String {
        return try await runAxeWithOutput(arguments)
    }

    private func runAxeWithOutput(_ arguments: [String]) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: Self.axePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PlaywrightError.axeCommandFailed(arguments.first ?? "unknown", errorMessage)
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }

    // MARK: - Cookie Management

    /// Get all cookies for current page
    public func getCookies() async throws -> [BrowserCookie] {
        let response = try await sendCommand(.getCookies)
        guard response.success,
              let cookiesData = response.result?["cookies"] as? [[String: Any]] else {
            throw PlaywrightError.commandFailed("getCookies", response.error)
        }

        return cookiesData.compactMap { BrowserCookie(from: $0) }
    }

    /// Set cookies
    public func setCookies(_ cookies: [BrowserCookie]) async throws {
        let cookieData = cookies.map { $0.toDictionary() }
        let response = try await sendCommand(.setCookies(cookies: cookieData))
        guard response.success else {
            throw PlaywrightError.commandFailed("setCookies", response.error)
        }
    }

    /// Delete all cookies
    public func deleteCookies() async throws {
        let response = try await sendCommand(.deleteCookies)
        guard response.success else {
            throw PlaywrightError.commandFailed("deleteCookies", response.error)
        }
    }

    /// Save cookies to file for a domain
    public func saveCookies(for domain: String) async throws {
        let cookies = try await getCookies()
        let domainCookies = cookies.filter { $0.domain.contains(domain) }

        let fileURL = cookieStorageURL.appendingPathComponent("\(domain.replacingOccurrences(of: ".", with: "_")).json")
        let data = try JSONEncoder().encode(domainCookies)
        try data.write(to: fileURL)
    }

    /// Load cookies from file for a domain
    public func loadCookies(for domain: String) async throws {
        let fileURL = cookieStorageURL.appendingPathComponent("\(domain.replacingOccurrences(of: ".", with: "_")).json")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return // No saved cookies
        }

        let data = try Data(contentsOf: fileURL)
        let cookies = try JSONDecoder().decode([BrowserCookie].self, from: data)
        try await setCookies(cookies)
    }

    /// Delete saved cookies for a domain
    public func deleteSavedCookies(for domain: String) throws {
        let fileURL = cookieStorageURL.appendingPathComponent("\(domain.replacingOccurrences(of: ".", with: "_")).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// List all saved cookie domains
    public func listSavedCookieDomains() throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(at: cookieStorageURL, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: ".") }
    }

    // MARK: - Private Methods

    private func installBrowserApp(udid: String) async throws {
        // Check if AtlBrowser.app exists
        let appBundle = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AtlBrowser.app")

        guard FileManager.default.fileExists(atPath: appBundle.path) else {
            throw PlaywrightError.browserAppNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "install", udid, appBundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PlaywrightError.browserInstallFailed
        }
    }

    private func launchBrowserApp(udid: String) async throws {
        let bundleId = "com.atl.browser"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "launch", udid, bundleId]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PlaywrightError.browserLaunchFailed
        }
    }

    private func terminateBrowserApp(udid: String) async throws {
        let bundleId = "com.atl.browser"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "terminate", udid, bundleId]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
    }

    private func waitForBrowserConnection(timeout: TimeInterval = 30) async throws {
        guard let udid = activeSimulatorUDID else {
            throw PlaywrightError.notConnected
        }

        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            // Try to connect to the browser's HTTP server
            // The server runs inside the simulator, accessible via simctl port forwarding

            // First, set up port forwarding
            try await setupPortForwarding(udid: udid)

            // Try a ping request
            if await pingBrowser() {
                return
            }

            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        throw PlaywrightError.connectionTimeout
    }

    private func setupPortForwarding(udid: String) async throws {
        // xcrun simctl spawn to set up port forwarding
        // The browser app listens on port 9222 inside the simulator
        // We need to forward that to the host

        // Note: iOS Simulator shares the network stack with the host,
        // so we can actually connect directly via localhost
        // No explicit port forwarding needed for iOS Simulator (unlike Android)
    }

    private func pingBrowser() async -> Bool {
        guard let url = URL(string: "http://localhost:\(browserPort)/ping") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Connection failed, browser not ready
        }

        return false
    }

    private func sendCommand(_ command: BrowserCommand) async throws -> CommandResponse {
        guard isConnected else {
            throw PlaywrightError.notConnected
        }

        guard let url = URL(string: "http://localhost:\(browserPort)/command") else {
            throw PlaywrightError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        request.timeoutInterval = command.timeout ?? 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PlaywrightError.commandFailed(command.method, "HTTP error")
        }

        return try JSONDecoder().decode(CommandResponse.self, from: data)
    }
}

// MARK: - Browser Command

public struct BrowserCommand: Codable {
    public let id: String
    public let method: String
    public let params: [String: AnyCodable]
    public var timeout: TimeInterval?

    private init(method: String, params: [String: AnyCodable] = [:], timeout: TimeInterval? = nil) {
        self.id = UUID().uuidString
        self.method = method
        self.params = params
        self.timeout = timeout
    }

    // Navigation
    static func goto(url: String) -> BrowserCommand {
        BrowserCommand(method: "goto", params: ["url": AnyCodable(url)])
    }

    static var reload: BrowserCommand {
        BrowserCommand(method: "reload")
    }

    static var goBack: BrowserCommand {
        BrowserCommand(method: "goBack")
    }

    static var goForward: BrowserCommand {
        BrowserCommand(method: "goForward")
    }

    static var getURL: BrowserCommand {
        BrowserCommand(method: "getURL")
    }

    static var getTitle: BrowserCommand {
        BrowserCommand(method: "getTitle")
    }

    // Interactions
    static func click(selector: String) -> BrowserCommand {
        BrowserCommand(method: "click", params: ["selector": AnyCodable(selector)])
    }

    static func doubleClick(selector: String) -> BrowserCommand {
        BrowserCommand(method: "doubleClick", params: ["selector": AnyCodable(selector)])
    }

    static func type(text: String, delay: TimeInterval) -> BrowserCommand {
        BrowserCommand(method: "type", params: ["text": AnyCodable(text), "delay": AnyCodable(delay)])
    }

    static func fill(selector: String, value: String) -> BrowserCommand {
        BrowserCommand(method: "fill", params: ["selector": AnyCodable(selector), "value": AnyCodable(value)])
    }

    static func press(key: String) -> BrowserCommand {
        BrowserCommand(method: "press", params: ["key": AnyCodable(key)])
    }

    static func hover(selector: String) -> BrowserCommand {
        BrowserCommand(method: "hover", params: ["selector": AnyCodable(selector)])
    }

    static func scrollIntoView(selector: String) -> BrowserCommand {
        BrowserCommand(method: "scrollIntoView", params: ["selector": AnyCodable(selector)])
    }

    // Selectors
    static func querySelector(selector: String) -> BrowserCommand {
        BrowserCommand(method: "querySelector", params: ["selector": AnyCodable(selector)])
    }

    static func querySelectorAll(selector: String) -> BrowserCommand {
        BrowserCommand(method: "querySelectorAll", params: ["selector": AnyCodable(selector)])
    }

    static func waitForSelector(selector: String, timeout: TimeInterval) -> BrowserCommand {
        BrowserCommand(method: "waitForSelector", params: ["selector": AnyCodable(selector)], timeout: timeout)
    }

    static func waitForNavigation(timeout: TimeInterval) -> BrowserCommand {
        BrowserCommand(method: "waitForNavigation", timeout: timeout)
    }

    // JavaScript
    static func evaluate(script: String) -> BrowserCommand {
        BrowserCommand(method: "evaluate", params: ["script": AnyCodable(script)])
    }

    // Screenshots
    static func screenshot(fullPage: Bool, selector: String?) -> BrowserCommand {
        var params: [String: AnyCodable] = ["fullPage": AnyCodable(fullPage)]
        if let selector = selector {
            params["selector"] = AnyCodable(selector)
        }
        return BrowserCommand(method: "screenshot", params: params)
    }

    // Cookies
    static var getCookies: BrowserCommand {
        BrowserCommand(method: "getCookies")
    }

    static func setCookies(cookies: [[String: Any]]) -> BrowserCommand {
        BrowserCommand(method: "setCookies", params: ["cookies": AnyCodable(cookies)])
    }

    static var deleteCookies: BrowserCommand {
        BrowserCommand(method: "deleteCookies")
    }
}

// MARK: - Command Response

public struct CommandResponse: Codable {
    public let id: String
    public let success: Bool
    public let result: [String: AnyCodable]?
    public let error: String?
}

// MARK: - Element

/// Represents a DOM element returned from the browser
/// Note: htmlContent is read-only data received from the browser for inspection
public struct Element: Sendable {
    public let tagName: String
    public let id: String?
    public let className: String?
    public let textContent: String?
    public let htmlContent: String?  // Raw HTML content for inspection (read-only)
    public let attributes: [String: String]
    public let boundingRect: CGRect?

    init?(from dict: [String: Any]) {
        guard let tagName = dict["tagName"] as? String else { return nil }

        self.tagName = tagName
        self.id = dict["id"] as? String
        self.className = dict["className"] as? String
        self.textContent = dict["textContent"] as? String
        self.htmlContent = dict["htmlContent"] as? String
        self.attributes = dict["attributes"] as? [String: String] ?? [:]

        if let rect = dict["boundingRect"] as? [String: Double] {
            self.boundingRect = CGRect(
                x: rect["x"] ?? 0,
                y: rect["y"] ?? 0,
                width: rect["width"] ?? 0,
                height: rect["height"] ?? 0
            )
        } else {
            self.boundingRect = nil
        }
    }
}

// MARK: - Browser Cookie

public struct BrowserCookie: Codable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expires: Date?
    public let httpOnly: Bool
    public let secure: Bool
    public let sameSite: String?

    init?(from dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let value = dict["value"] as? String,
              let domain = dict["domain"] as? String else {
            return nil
        }

        self.name = name
        self.value = value
        self.domain = domain
        self.path = dict["path"] as? String ?? "/"

        if let expiresTimestamp = dict["expires"] as? TimeInterval {
            self.expires = Date(timeIntervalSince1970: expiresTimestamp)
        } else {
            self.expires = nil
        }

        self.httpOnly = dict["httpOnly"] as? Bool ?? false
        self.secure = dict["secure"] as? Bool ?? false
        self.sameSite = dict["sameSite"] as? String
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "value": value,
            "domain": domain,
            "path": path,
            "httpOnly": httpOnly,
            "secure": secure
        ]

        if let expires = expires {
            dict["expires"] = expires.timeIntervalSince1970
        }

        if let sameSite = sameSite {
            dict["sameSite"] = sameSite
        }

        return dict
    }
}

// MARK: - AnyCodable Helper

public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode value")
            throw EncodingError.invalidValue(value, context)
        }
    }
}

// MARK: - Errors

public enum PlaywrightError: LocalizedError {
    case notConnected
    case connectionTimeout
    case simulatorBootFailed
    case noSimulatorsAvailable
    case browserAppNotFound
    case browserInstallFailed
    case browserLaunchFailed
    case navigationFailed(String)
    case elementNotFound(String)
    case timeout(String)
    case javascriptError(String)
    case screenshotFailed
    case commandFailed(String, String?)
    case invalidURL
    case axeCommandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to browser"
        case .connectionTimeout:
            return "Timed out connecting to browser"
        case .simulatorBootFailed:
            return "Failed to boot simulator"
        case .noSimulatorsAvailable:
            return "No iOS simulators available"
        case .browserAppNotFound:
            return "AtlBrowser.app not found"
        case .browserInstallFailed:
            return "Failed to install browser app"
        case .browserLaunchFailed:
            return "Failed to launch browser app"
        case .navigationFailed(let message):
            return "Navigation failed: \(message)"
        case .elementNotFound(let selector):
            return "Element not found: \(selector)"
        case .timeout(let message):
            return "Timeout: \(message)"
        case .javascriptError(let message):
            return "JavaScript error: \(message)"
        case .screenshotFailed:
            return "Failed to capture screenshot"
        case .commandFailed(let command, let error):
            return "Command '\(command)' failed: \(error ?? "Unknown error")"
        case .invalidURL:
            return "Invalid URL"
        case .axeCommandFailed(let command, let error):
            return "AXe command '\(command)' failed: \(error)"
        }
    }
}

// MARK: - Simulator Gesture Presets

public enum SimulatorGesture: String {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down"
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case swipeFromLeftEdge = "swipe-from-left-edge"
    case swipeFromRightEdge = "swipe-from-right-edge"
    case swipeFromTopEdge = "swipe-from-top-edge"
    case swipeFromBottomEdge = "swipe-from-bottom-edge"
}

// MARK: - Simulator Hardware Buttons

public enum SimulatorButton: String {
    case home = "home"
    case lock = "lock"
    case sideButton = "side-button"
    case siri = "siri"
    case applePay = "apple-pay"
}
