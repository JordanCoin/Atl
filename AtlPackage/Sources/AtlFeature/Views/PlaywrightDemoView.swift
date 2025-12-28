import SwiftUI

// MARK: - Playwright Demo View

/// Interactive demo view to test Playwright automation actions
public struct PlaywrightDemoView: View {
    @StateObject private var viewModel = PlaywrightDemoViewModel()
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // Status Section
                Section {
                    HStack {
                        Circle()
                            .fill(viewModel.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(viewModel.isConnected ? "Connected" : "Not Connected")
                        Spacer()
                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }

                    if !viewModel.statusMessage.isEmpty {
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Status")
                }

                // Simulator Selection
                Section {
                    Picker("Simulator", selection: $viewModel.selectedSimulatorUDID) {
                        Text("None").tag(nil as String?)
                        ForEach(viewModel.availableSimulators, id: \.udid) { sim in
                            HStack {
                                Text(sim.name)
                                if sim.state.lowercased() == "booted" {
                                    Text("(Booted)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(sim.udid as String?)
                        }
                    }

                    Button {
                        Task {
                            await viewModel.refreshSimulators()
                        }
                    } label: {
                        Label("Refresh Simulators", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Simulator")
                }

                // Connection Section
                Section {
                    ActionRow(
                        icon: "power",
                        title: "Launch Browser",
                        subtitle: "Boot simulator & install AtlBrowser",
                        color: .green
                    ) {
                        await viewModel.launch()
                    }

                    ActionRow(
                        icon: "link.badge.plus",
                        title: "Disconnect",
                        subtitle: "Disconnect but keep browser running",
                        color: .orange
                    ) {
                        await viewModel.disconnect()
                    }

                    ActionRow(
                        icon: "xmark.app",
                        title: "Close Browser",
                        subtitle: "Terminate AtlBrowser app",
                        color: .red
                    ) {
                        await viewModel.closeBrowser()
                    }

                    ActionRow(
                        icon: "stop.circle.fill",
                        title: "Stop Simulator",
                        subtitle: "Shutdown the entire simulator",
                        color: .red
                    ) {
                        await viewModel.stopSimulator()
                    }
                } header: {
                    Text("Connection")
                }

                // Navigation Section
                Section {
                    ActionRow(
                        icon: "globe",
                        title: "Go to Example.com",
                        subtitle: "Navigate to example.com",
                        color: .blue
                    ) {
                        await viewModel.navigateTo("https://example.com")
                    }

                    ActionRow(
                        icon: "applelogo",
                        title: "Go to Apple.com",
                        subtitle: "Navigate to apple.com",
                        color: .gray
                    ) {
                        await viewModel.navigateTo("https://apple.com")
                    }

                    ActionRow(
                        icon: "magnifyingglass",
                        title: "Go to Google",
                        subtitle: "Navigate to google.com",
                        color: .orange
                    ) {
                        await viewModel.navigateTo("https://google.com")
                    }

                    ActionRow(
                        icon: "newspaper",
                        title: "Go to Hacker News",
                        subtitle: "Navigate to news.ycombinator.com",
                        color: .orange
                    ) {
                        await viewModel.navigateTo("https://news.ycombinator.com")
                    }
                } header: {
                    Text("Navigation")
                }

                // Interactions Section
                Section {
                    ActionRow(
                        icon: "hand.tap",
                        title: "Click First Link",
                        subtitle: "Click the first <a> element",
                        color: .purple
                    ) {
                        await viewModel.clickFirstLink()
                    }

                    ActionRow(
                        icon: "character.cursor.ibeam",
                        title: "Type in Search",
                        subtitle: "Type 'Hello World' in first input",
                        color: .indigo
                    ) {
                        await viewModel.typeInInput()
                    }

                    ActionRow(
                        icon: "arrow.backward",
                        title: "Go Back",
                        subtitle: "Navigate back in history",
                        color: .gray
                    ) {
                        await viewModel.goBack()
                    }

                    ActionRow(
                        icon: "arrow.clockwise",
                        title: "Reload Page",
                        subtitle: "Refresh current page",
                        color: .blue
                    ) {
                        await viewModel.reload()
                    }
                } header: {
                    Text("Web Interactions (JavaScript)")
                }

                // AXe Simulator Actions
                Section {
                    ActionRow(
                        icon: "hand.point.up",
                        title: "Tap Center",
                        subtitle: "Tap at screen center (200, 400)",
                        color: .pink
                    ) {
                        await viewModel.simulatorTapCenter()
                    }

                    ActionRow(
                        icon: "arrow.down",
                        title: "Scroll Down",
                        subtitle: "Scroll down gesture",
                        color: .teal
                    ) {
                        await viewModel.simulatorScrollDown()
                    }

                    ActionRow(
                        icon: "arrow.up",
                        title: "Scroll Up",
                        subtitle: "Scroll up gesture",
                        color: .teal
                    ) {
                        await viewModel.simulatorScrollUp()
                    }

                    ActionRow(
                        icon: "keyboard",
                        title: "Type 'test'",
                        subtitle: "Type using simulator keyboard",
                        color: .mint
                    ) {
                        await viewModel.simulatorTypeText()
                    }

                    ActionRow(
                        icon: "house",
                        title: "Press Home",
                        subtitle: "Press home button",
                        color: .gray
                    ) {
                        await viewModel.simulatorPressHome()
                    }
                } header: {
                    Text("Simulator Actions (AXe)")
                }

                // Info Section
                Section {
                    ActionRow(
                        icon: "doc.text",
                        title: "Get Page Title",
                        subtitle: "Evaluate document.title",
                        color: .cyan
                    ) {
                        await viewModel.getPageTitle()
                    }

                    ActionRow(
                        icon: "link",
                        title: "Get Current URL",
                        subtitle: "Get current page URL",
                        color: .cyan
                    ) {
                        await viewModel.getCurrentURL()
                    }

                    ActionRow(
                        icon: "list.bullet.rectangle",
                        title: "Count Links",
                        subtitle: "Count all <a> elements",
                        color: .cyan
                    ) {
                        await viewModel.countLinks()
                    }

                    ActionRow(
                        icon: "eye",
                        title: "Describe UI",
                        subtitle: "Get accessibility tree (AXe)",
                        color: .brown
                    ) {
                        await viewModel.describeUI()
                    }
                } header: {
                    Text("Page Info")
                }

                // Screenshots Section
                Section {
                    ActionRow(
                        icon: "camera",
                        title: "Screenshot (WebView)",
                        subtitle: "Capture WebView content",
                        color: .green
                    ) {
                        await viewModel.screenshotWebView()
                    }

                    ActionRow(
                        icon: "camera.viewfinder",
                        title: "Screenshot (Simulator)",
                        subtitle: "Capture full simulator via AXe",
                        color: .green
                    ) {
                        await viewModel.screenshotSimulator()
                    }
                } header: {
                    Text("Screenshots")
                }

                // Cookies Section
                Section {
                    ActionRow(
                        icon: "tray.and.arrow.down",
                        title: "Save Cookies",
                        subtitle: "Save cookies for current domain",
                        color: .yellow
                    ) {
                        await viewModel.saveCookies()
                    }

                    ActionRow(
                        icon: "tray.and.arrow.up",
                        title: "Load Cookies",
                        subtitle: "Load saved cookies",
                        color: .yellow
                    ) {
                        await viewModel.loadCookies()
                    }

                    ActionRow(
                        icon: "trash",
                        title: "Delete Cookies",
                        subtitle: "Clear all cookies",
                        color: .red
                    ) {
                        await viewModel.deleteCookies()
                    }
                } header: {
                    Text("Cookies")
                }
            }
            .navigationTitle("Playwright Demo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }
}

// MARK: - Action Row

struct ActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () async -> Void

    @State private var isRunning = false

    var body: some View {
        Button {
            Task {
                isRunning = true
                await action()
                isRunning = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isRunning {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
        .disabled(isRunning)
    }
}

// MARK: - View Model

@MainActor
class PlaywrightDemoViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var statusMessage = "Not connected"
    @Published var availableSimulators: [SimulatorManager.SimulatorInfo] = []
    @Published var selectedSimulatorUDID: String?

    private var simulatorUDID: String?

    init() {
        Task {
            await refreshSimulators()
        }
    }

    func refreshSimulators() async {
        availableSimulators = await SimulatorManager.shared.fetchSimulators()
        // Auto-select first booted simulator, or first available
        if selectedSimulatorUDID == nil {
            if let booted = availableSimulators.first(where: { $0.state.lowercased() == "booted" }) {
                selectedSimulatorUDID = booted.udid
            } else if let first = availableSimulators.first {
                selectedSimulatorUDID = first.udid
            }
        }
    }

    var selectedSimulatorName: String {
        if let udid = selectedSimulatorUDID,
           let sim = availableSimulators.first(where: { $0.udid == udid }) {
            return sim.name
        }
        return "None"
    }

    // MARK: - Connection

    func launch() async {
        guard let udid = selectedSimulatorUDID else {
            statusMessage = "No simulator selected"
            return
        }

        guard let simulator = availableSimulators.first(where: { $0.udid == udid }) else {
            statusMessage = "Simulator not found"
            return
        }

        isLoading = true
        statusMessage = "Launching \(simulator.name)..."

        // Boot if not already booted
        if simulator.state.lowercased() != "booted" {
            statusMessage = "Booting \(simulator.name)..."
            let bootSuccess = await SimulatorManager.shared.bootSimulator(udid: udid)
            if !bootSuccess {
                statusMessage = "Failed to boot simulator"
                isLoading = false
                return
            }
            await SimulatorManager.shared.openSimulatorApp(udid: udid)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Install and launch AtlBrowser
        statusMessage = "Installing AtlBrowser..."
        let browserSuccess = await SimulatorManager.shared.ensureAtlBrowserRunning(
            udid: udid,
            url: "https://www.apple.com"
        )

        if browserSuccess {
            simulatorUDID = udid
            // Wait for the HTTP server to start
            statusMessage = "Waiting for browser to start..."
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Test connection
            let connected = await testConnection(udid: udid)
            if connected {
                statusMessage = "Connected to \(simulator.name)"
                isConnected = true
            } else {
                statusMessage = "Browser running but HTTP server not responding. Try again."
                isConnected = false
            }
        } else {
            statusMessage = "Failed to launch AtlBrowser"
            isConnected = false
        }

        isLoading = false
        await refreshSimulators()
    }

    private func testConnection(udid: String) async -> Bool {
        // Retry up to 5 times with delay
        for attempt in 1...5 {
            statusMessage = "Testing connection (attempt \(attempt)/5)..."

            if await pingServer() {
                return true
            }

            // Wait before retry
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private func pingServer() async -> Bool {
        guard let url = URL(string: "http://localhost:9222/command") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3

        let body: [String: Any] = ["method": "evaluate", "params": ["script": "'ping'"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Just disconnect from the browser (keep it running)
    func disconnect() async {
        isConnected = false
        simulatorUDID = nil
        statusMessage = "Disconnected"
    }

    /// Terminate AtlBrowser app on the simulator
    func closeBrowser() async {
        guard let udid = selectedSimulatorUDID else {
            statusMessage = "No simulator selected"
            return
        }

        isLoading = true
        statusMessage = "Closing AtlBrowser..."

        // Terminate the app using simctl
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "terminate", udid, "com.atl.browser"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            isConnected = false
            simulatorUDID = nil
            statusMessage = "Browser closed"
        } catch {
            statusMessage = "Failed to close browser"
        }

        isLoading = false
    }

    /// Stop the entire simulator
    func stopSimulator() async {
        guard let udid = selectedSimulatorUDID else {
            statusMessage = "No simulator selected"
            return
        }

        guard let simulator = availableSimulators.first(where: { $0.udid == udid }) else {
            statusMessage = "Simulator not found"
            return
        }

        isLoading = true
        statusMessage = "Stopping \(simulator.name)..."

        let success = await SimulatorManager.shared.shutdownSimulator(udid: udid)

        if success {
            isConnected = false
            simulatorUDID = nil
            statusMessage = "Simulator stopped"
        } else {
            statusMessage = "Failed to stop simulator"
        }

        isLoading = false
        await refreshSimulators()
    }

    func refresh() async {
        if let udid = simulatorUDID {
            let simulators = await SimulatorManager.shared.fetchSimulators()
            if let sim = simulators.first(where: { $0.udid == udid }) {
                isConnected = sim.state.lowercased() == "booted"
                statusMessage = isConnected ? "Connected to \(sim.name)" : "Simulator not running"
            }
        }
    }

    // MARK: - Navigation

    func navigateTo(_ url: String) async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        statusMessage = "Navigating to \(url)..."

        do {
            let result = try await sendCommand(to: udid, method: "goto", params: ["url": url])
            if result {
                statusMessage = "Navigated to \(url)"
            } else {
                statusMessage = "Navigation failed"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func goBack() async {
        await executeCommand(method: "goBack", successMessage: "Went back")
    }

    func reload() async {
        await executeCommand(method: "reload", successMessage: "Page reloaded")
    }

    // MARK: - Interactions

    func clickFirstLink() async {
        await executeCommand(method: "click", params: ["selector": "a"], successMessage: "Clicked first link")
    }

    func typeInInput() async {
        // First click on input, then type
        _ = await executeCommand(method: "click", params: ["selector": "input"], successMessage: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await executeCommand(method: "fill", params: ["selector": "input", "value": "Hello World"], successMessage: "Typed 'Hello World'")
    }

    // MARK: - Simulator Actions (AXe)

    func simulatorTapCenter() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            try await runAxe(["tap", "-x", "200", "-y", "400", "--udid", udid])
            statusMessage = "Tapped at (200, 400)"
        } catch {
            statusMessage = "Tap failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func simulatorScrollDown() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            try await runAxe(["gesture", "scroll-down", "--udid", udid])
            statusMessage = "Scrolled down"
        } catch {
            statusMessage = "Scroll failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func simulatorScrollUp() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            try await runAxe(["gesture", "scroll-up", "--udid", udid])
            statusMessage = "Scrolled up"
        } catch {
            statusMessage = "Scroll failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func simulatorTypeText() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            try await runAxe(["type", "test", "--udid", udid])
            statusMessage = "Typed 'test'"
        } catch {
            statusMessage = "Type failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func simulatorPressHome() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            try await runAxe(["button", "home", "--udid", udid])
            statusMessage = "Pressed home button"
        } catch {
            statusMessage = "Button press failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Page Info

    func getPageTitle() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            let response = try await sendCommandWithResponse(to: udid, method: "evaluate", params: ["script": "document.title"])
            if let value = response["value"] as? String {
                statusMessage = "Title: \(value)"
            } else {
                statusMessage = "No title found"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func getCurrentURL() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            let response = try await sendCommandWithResponse(to: udid, method: "getURL", params: [:])
            if let url = response["url"] as? String {
                statusMessage = "URL: \(url)"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func countLinks() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            let response = try await sendCommandWithResponse(to: udid, method: "evaluate", params: ["script": "document.querySelectorAll('a').length"])
            if let count = response["value"] as? Int {
                statusMessage = "Found \(count) links"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func describeUI() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            let output = try await runAxeWithOutput(["describe-ui", "--udid", udid])
            let lines = output.components(separatedBy: .newlines).prefix(5)
            statusMessage = "UI Tree:\n\(lines.joined(separator: "\n"))..."
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Screenshots

    func screenshotWebView() async {
        await executeCommand(method: "screenshot", params: ["fullPage": false], successMessage: "Screenshot captured (WebView)")
    }

    func screenshotSimulator() async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            let outputPath = "/tmp/playwright-screenshot-\(UUID().uuidString).png"
            try await runAxe(["screenshot", "--output", outputPath, "--udid", udid])
            statusMessage = "Screenshot saved to \(outputPath)"
        } catch {
            statusMessage = "Screenshot failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Cookies

    func saveCookies() async {
        await executeCommand(method: "getCookies", successMessage: "Cookies retrieved (check logs)")
    }

    func loadCookies() async {
        statusMessage = "Cookie loading not implemented in demo"
    }

    func deleteCookies() async {
        await executeCommand(method: "deleteCookies", successMessage: "Cookies deleted")
    }

    // MARK: - Helpers

    private func executeCommand(method: String, params: [String: Any] = [:], successMessage: String?) async {
        guard let udid = simulatorUDID else {
            statusMessage = "Not connected"
            return
        }

        isLoading = true
        do {
            let result = try await sendCommand(to: udid, method: method, params: params)
            if result {
                statusMessage = successMessage ?? "Success"
            } else {
                statusMessage = "Command failed"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func sendCommand(to udid: String, method: String, params: [String: Any]) async throws -> Bool {
        let url = URL(string: "http://localhost:9222/command")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)

        if let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return response["success"] as? Bool ?? false
        }
        return false
    }

    private func sendCommandWithResponse(to udid: String, method: String, params: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "http://localhost:9222/command")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)

        if let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = response["result"] as? [String: Any] {
            return result
        }
        return [:]
    }

    private func runAxe(_ arguments: [String]) async throws {
        _ = try await runAxeWithOutput(arguments)
    }

    private func runAxeWithOutput(_ arguments: [String]) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/axe")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "AXe", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

// MARK: - Preview

#Preview {
    PlaywrightDemoView()
}
