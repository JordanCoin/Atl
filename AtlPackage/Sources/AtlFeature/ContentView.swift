import SwiftUI
import AppKit

// MARK: - Models

public struct SimulatorDevice: Identifiable, Hashable {
    public let id: UUID
    public let udid: String
    public var name: String
    public var platform: Platform
    public var status: DeviceStatus
    public var account: SocialAccount?

    public init(id: UUID = UUID(), udid: String = "", name: String, platform: Platform, status: DeviceStatus = .offline, account: SocialAccount? = nil) {
        self.id = id
        self.udid = udid
        self.name = name
        self.platform = platform
        self.status = status
        self.account = account
    }
}

public enum Platform: String, CaseIterable {
    case iOS = "iOS"
    case android = "Android"

    var icon: String {
        switch self {
        case .iOS: return "iphone"
        case .android: return "phone.fill"
        }
    }
}

public enum DeviceStatus: String {
    case online = "Online"
    case offline = "Offline"
    case running = "Running"

    var color: Color {
        switch self {
        case .online: return .green
        case .offline: return .secondary
        case .running: return .blue
        }
    }
}

public struct SocialAccount: Identifiable, Hashable {
    public let id: UUID
    public var username: String
    public var platform: SocialPlatform
    public var status: AccountStatus

    public init(id: UUID = UUID(), username: String, platform: SocialPlatform, status: AccountStatus = .active) {
        self.id = id
        self.username = username
        self.platform = platform
        self.status = status
    }
}

public enum SocialPlatform: String, CaseIterable {
    case instagram = "Instagram"
    case tiktok = "TikTok"
    case twitter = "X"
    case threads = "Threads"

    var icon: String {
        switch self {
        case .instagram: return "camera.fill"
        case .tiktok: return "music.note"
        case .twitter: return "at"
        case .threads: return "at.circle.fill"
        }
    }
}

public enum AccountStatus: String {
    case active = "Active"
    case suspended = "Suspended"
    case pending = "Pending"

    var color: Color {
        switch self {
        case .active: return .green
        case .suspended: return .red
        case .pending: return .orange
        }
    }
}

// MARK: - Log Entry Model

public struct LogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
    public let source: String

    public enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"

        var color: Color {
            switch self {
            case .debug: return .secondary
            case .info: return .primary
            case .warning: return .orange
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .debug: return "ant.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }
}

// MARK: - Simulator Log Streamer

@MainActor
public class SimulatorLogStreamer: ObservableObject {
    @Published public var logs: [LogEntry] = []
    @Published public var isStreaming: Bool = false

    private var logProcess: Process?
    private var outputPipe: Pipe?
    private var currentUDID: String?

    public init() {}

    public func startStreaming(udid: String) {
        stopStreaming()

        currentUDID = udid
        isStreaming = true
        logs = []

        // Add initial log entry
        addLog(level: .info, message: "Starting log capture for simulator...", source: "System")

        Task {
            await streamLogs(udid: udid)
        }
    }

    private func streamLogs(udid: String) async {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // Use simctl spawn to run log stream inside the simulator
        process.arguments = ["simctl", "spawn", udid, "log", "stream", "--level", "debug", "--style", "compact"]
        process.standardOutput = pipe
        process.standardError = pipe

        logProcess = process
        outputPipe = pipe

        do {
            try process.run()

            addLog(level: .info, message: "Connected to simulator log stream", source: "System")

            let fileHandle = pipe.fileHandleForReading

            // Read output asynchronously
            fileHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    return
                }

                if let output = String(data: data, encoding: .utf8) {
                    Task { @MainActor [weak self] in
                        self?.processLogOutput(output)
                    }
                }
            }

            // Monitor process termination
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isStreaming = false
                    self?.addLog(level: .info, message: "Log stream ended", source: "System")
                }
            }

        } catch {
            addLog(level: .error, message: "Failed to start log stream: \(error.localizedDescription)", source: "System")
            isStreaming = false
        }
    }

    private func processLogOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Parse log level from the line
            let level: LogEntry.LogLevel
            let lowercased = trimmed.lowercased()

            if lowercased.contains("error") || lowercased.contains("fault") {
                level = .error
            } else if lowercased.contains("warning") || lowercased.contains("warn") {
                level = .warning
            } else if lowercased.contains("debug") {
                level = .debug
            } else {
                level = .info
            }

            // Extract source from log line (typically the process name)
            let source = extractSource(from: trimmed)

            addLog(level: level, message: trimmed, source: source)
        }
    }

    private func extractSource(from line: String) -> String {
        // Try to extract process name from log format
        // Typical format: timestamp processName[pid]: message
        let components = line.components(separatedBy: " ")
        if components.count > 2 {
            let processComponent = components[1]
            if let bracketIndex = processComponent.firstIndex(of: "[") {
                return String(processComponent[..<bracketIndex])
            }
            return processComponent
        }
        return "Unknown"
    }

    private func addLog(level: LogEntry.LogLevel, message: String, source: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message, source: source)
        logs.append(entry)

        // Keep only last 500 logs to prevent memory issues
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    public func stopStreaming() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        logProcess?.terminate()
        logProcess = nil
        outputPipe = nil
        currentUDID = nil
        isStreaming = false
    }

    public func clearLogs() {
        logs = []
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        logProcess?.terminate()
    }
}

// MARK: - Simulator Manager

public final class SimulatorManager: Sendable {
    public static let shared = SimulatorManager()

    private init() {}

    public struct SimulatorInfo {
        public let udid: String
        public let name: String
        public let state: String
        public let runtime: String
    }

    public func fetchSimulators() async -> [SimulatorInfo] {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [String: [[String: Any]]] else {
                return []
            }

            var simulators: [SimulatorInfo] = []
            for (runtime, deviceList) in devices {
                // Only include iOS simulators
                guard runtime.contains("iOS") else { continue }

                for device in deviceList {
                    guard let udid = device["udid"] as? String,
                          let name = device["name"] as? String,
                          let state = device["state"] as? String,
                          device["isAvailable"] as? Bool == true else { continue }

                    simulators.append(SimulatorInfo(
                        udid: udid,
                        name: name,
                        state: state,
                        runtime: runtime
                    ))
                }
            }

            return simulators.sorted { $0.name < $1.name }
        } catch {
            print("Failed to fetch simulators: \(error)")
            return []
        }
    }

    public func bootSimulator(udid: String) async -> Bool {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "boot", udid]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let status = process.terminationStatus
            // 0 = success, 149 = already booted (not an error)
            if status == 0 || status == 149 {
                return true
            }

            // Log any error output for debugging
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorMessage = String(data: errorData, encoding: .utf8), !errorMessage.isEmpty {
                print("Simulator boot error: \(errorMessage)")
            }
            return false
        } catch {
            print("Failed to boot simulator: \(error)")
            return false
        }
    }

    public func shutdownSimulator(udid: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "shutdown", udid]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("Failed to shutdown simulator: \(error)")
            return false
        }
    }

    public func openSimulatorApp(udid: String? = nil) async {
        // Open the Simulator app with the specific device UDID
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        if let udid = udid {
            // Pass the device UDID to Simulator.app so it opens that specific device window
            openProcess.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        } else {
            openProcess.arguments = ["-a", "Simulator"]
        }

        do {
            try openProcess.run()
            openProcess.waitUntilExit()
        } catch {
            print("Failed to open Simulator app: \(error)")
            return
        }

        // Give Simulator app time to launch and show the device window
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Bring Simulator to foreground
        let activateProcess = Process()
        activateProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activateProcess.arguments = ["-e", "tell application \"Simulator\" to activate"]
        try? activateProcess.run()
        activateProcess.waitUntilExit()
    }

    public func openSafari(udid: String, url: String = "https://www.apple.com") async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "openurl", udid, url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to open Safari: \(error)")
        }
    }

    // MARK: - AtlBrowser App Management

    private let atlBrowserBundleId = "com.atl.browser"

    /// Check if AtlBrowser is installed on the simulator
    public func isAtlBrowserInstalled(udid: String) async -> Bool {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "get_app_container", udid, atlBrowserBundleId]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Get the path to the embedded AtlBrowser.app in our bundle
    public func getEmbeddedAtlBrowserPath() -> URL? {
        // Look for AtlBrowser.app in our app bundle's Resources
        if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("AtlBrowser.app") {
            if FileManager.default.fileExists(atPath: bundlePath.path) {
                return bundlePath
            }
        }

        // Also check in PlugIns directory (alternative location)
        if let pluginsPath = Bundle.main.builtInPlugInsURL?.appendingPathComponent("AtlBrowser.app") {
            if FileManager.default.fileExists(atPath: pluginsPath.path) {
                return pluginsPath
            }
        }

        // Fallback: Check derived data for development builds
        let derivedDataPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")

        if let enumerator = FileManager.default.enumerator(at: derivedDataPath, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                if url.lastPathComponent == "AtlBrowser.app" &&
                   url.pathComponents.contains("Debug-iphonesimulator") {
                    return url
                }
            }
        }

        return nil
    }

    /// Install AtlBrowser on the simulator
    public func installAtlBrowser(udid: String) async -> Bool {
        guard let appPath = getEmbeddedAtlBrowserPath() else {
            print("AtlBrowser.app not found in bundle")
            return false
        }

        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "install", udid, appPath.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorMessage = String(data: errorData, encoding: .utf8) {
                    print("Failed to install AtlBrowser: \(errorMessage)")
                }
                return false
            }
            return true
        } catch {
            print("Failed to install AtlBrowser: \(error)")
            return false
        }
    }

    /// Launch AtlBrowser on the simulator
    public func launchAtlBrowser(udid: String, url: String? = nil) async -> Bool {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["simctl", "launch", udid, atlBrowserBundleId]
        if let url = url {
            args.append(contentsOf: ["--url", url])
        }
        process.arguments = args

        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorMessage = String(data: errorData, encoding: .utf8) {
                    print("Failed to launch AtlBrowser: \(errorMessage)")
                }
                return false
            }
            return true
        } catch {
            print("Failed to launch AtlBrowser: \(error)")
            return false
        }
    }

    /// Install (if needed) and launch AtlBrowser
    public func ensureAtlBrowserRunning(udid: String, url: String? = nil) async -> Bool {
        // Check if already installed
        let installed = await isAtlBrowserInstalled(udid: udid)

        if !installed {
            print("AtlBrowser not installed, installing...")
            let installSuccess = await installAtlBrowser(udid: udid)
            if !installSuccess {
                print("Failed to install AtlBrowser")
                return false
            }
            // Give it a moment after install
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Launch the app
        return await launchAtlBrowser(udid: udid, url: url)
    }
}

// MARK: - View Model

@MainActor
public class FarmViewModel: ObservableObject {
    @Published public var devices: [SimulatorDevice] = []
    @Published public var accounts: [SocialAccount] = []
    @Published public var selectedDevice: SimulatorDevice?
    @Published public var searchText: String = ""
    @Published public var isLoading: Bool = false
    @Published public var logStreamer = SimulatorLogStreamer()

    private let simulatorManager = SimulatorManager.shared

    public init() {
        loadSampleAccounts()
        Task {
            await refreshSimulators()
        }
    }

    private func loadSampleAccounts() {
        accounts = [
            SocialAccount(username: "@creator_one", platform: .instagram, status: .active),
            SocialAccount(username: "@viral_content", platform: .tiktok, status: .active),
            SocialAccount(username: "@news_feed", platform: .twitter, status: .pending),
            SocialAccount(username: "@daily_posts", platform: .threads, status: .active),
        ]
    }

    public func refreshSimulators() async {
        isLoading = true
        let simulators = await simulatorManager.fetchSimulators()

        devices = simulators.map { sim in
            let status: DeviceStatus
            switch sim.state.lowercased() {
            case "booted":
                status = .running
            case "shutdown":
                status = .offline
            default:
                status = .offline
            }

            return SimulatorDevice(
                udid: sim.udid,
                name: sim.name,
                platform: .iOS,
                status: status
            )
        }
        isLoading = false
    }

    public var filteredDevices: [SimulatorDevice] {
        if searchText.isEmpty {
            return devices
        }
        return devices.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public func addDevice(name: String, platform: Platform) {
        let device = SimulatorDevice(name: name, platform: platform)
        devices.append(device)
    }

    public func removeDevice(_ device: SimulatorDevice) {
        devices.removeAll { $0.id == device.id }
        if selectedDevice?.id == device.id {
            selectedDevice = nil
        }
    }

    public func toggleDeviceStatus(_ device: SimulatorDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }

        let currentDevice = devices[index]

        Task {
            if currentDevice.status == .running {
                // Stop log streaming first
                logStreamer.stopStreaming()

                // Shutdown the simulator
                let success = await simulatorManager.shutdownSimulator(udid: currentDevice.udid)
                if success {
                    devices[index].status = .offline
                }
            } else {
                // Boot the simulator and open Safari
                devices[index].status = .online // Show as "online" while booting

                let success = await simulatorManager.bootSimulator(udid: currentDevice.udid)
                if success {
                    // Open Simulator app with the specific device
                    await simulatorManager.openSimulatorApp(udid: currentDevice.udid)
                    // Wait a moment for the simulator to fully boot and UI to appear
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

                    // Install and launch AtlBrowser instead of Safari
                    let browserSuccess = await simulatorManager.ensureAtlBrowserRunning(
                        udid: currentDevice.udid,
                        url: "https://www.apple.com"
                    )
                    if !browserSuccess {
                        print("Warning: AtlBrowser failed to launch, falling back to Safari")
                        await simulatorManager.openSafari(udid: currentDevice.udid)
                    }

                    devices[index].status = .running

                    // Start streaming logs
                    logStreamer.startStreaming(udid: currentDevice.udid)
                } else {
                    devices[index].status = .offline
                }
            }
        }
    }

    public func addAccount(username: String, platform: SocialPlatform) {
        let account = SocialAccount(username: username, platform: platform)
        accounts.append(account)
    }

    public func removeAccount(_ account: SocialAccount) {
        accounts.removeAll { $0.id == account.id }
    }
}

// MARK: - Main View

public struct ContentView: View {
    @StateObject private var viewModel = FarmViewModel()
    @State private var showingAddDevice = false
    @State private var showingAddAccount = false
    @State private var showingPlaywrightDemo = false
    @State private var showingTaskRunner = false
    @State private var showingVisionAutomation = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
        } detail: {
            DetailView(viewModel: viewModel)
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { showingVisionAutomation = true }) {
                    Image(systemName: "eye")
                }
                .help("Vision Automation")

                Button(action: { showingTaskRunner = true }) {
                    Image(systemName: "play.circle")
                }
                .help("Task Runner")

                Button(action: { showingPlaywrightDemo = true }) {
                    Image(systemName: "theatermasks")
                }
                .help("Playwright Demo")

                Button(action: { showingAddDevice = true }) {
                    Image(systemName: "plus")
                }
                .help("Add Device")
            }
        }
        .sheet(isPresented: $showingAddDevice) {
            AddDeviceSheet(viewModel: viewModel, isPresented: $showingAddDevice)
        }
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet(viewModel: viewModel, isPresented: $showingAddAccount)
        }
        .sheet(isPresented: $showingPlaywrightDemo) {
            PlaywrightDemoView()
                .frame(width: 500, height: 700)
        }
        .sheet(isPresented: $showingTaskRunner) {
            TaskRunnerView()
                .frame(width: 800, height: 600)
        }
        .sheet(isPresented: $showingVisionAutomation) {
            VisionAutomationView()
                .frame(width: 900, height: 650)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var viewModel: FarmViewModel

    var body: some View {
        List(selection: $viewModel.selectedDevice) {
            Section("Simulators") {
                ForEach(viewModel.filteredDevices) { device in
                    DeviceRow(device: device, viewModel: viewModel)
                        .tag(device)
                }
            }

            Section("Accounts") {
                ForEach(viewModel.accounts) { account in
                    AccountRow(account: account)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $viewModel.searchText, prompt: "Search")
        .frame(minWidth: 220)
    }
}

struct DeviceRow: View {
    let device: SimulatorDevice
    @ObservedObject var viewModel: FarmViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.platform.icon)
                .foregroundColor(.primary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))

                Text(device.status.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(device.status.color)
            }

            Spacer()

            Circle()
                .fill(device.status.color)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(device.status == .running ? "Stop" : "Start") {
                viewModel.toggleDeviceStatus(device)
            }
            Divider()
            Button("Remove", role: .destructive) {
                viewModel.removeDevice(device)
            }
        }
    }
}

struct AccountRow: View {
    let account: SocialAccount

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.platform.icon)
                .foregroundColor(.primary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.username)
                    .font(.system(size: 12, weight: .medium))

                Text(account.platform.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Circle()
                .fill(account.status.color)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail View

struct DetailView: View {
    @ObservedObject var viewModel: FarmViewModel

    var body: some View {
        if let device = viewModel.selectedDevice {
            DeviceDetailView(device: device, viewModel: viewModel)
        } else {
            EmptyStateView()
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("Select a Simulator")
                .font(.title2)
                .fontWeight(.medium)

            Text("Choose a device from the sidebar to view details")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceDetailView: View {
    let device: SimulatorDevice
    @ObservedObject var viewModel: FarmViewModel
    @State private var selectedTab: DetailTab = .overview

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case logs = "Logs"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        Label(device.platform.rawValue, systemImage: device.platform.icon)
                        Text("•")
                        Label(device.status.rawValue, systemImage: "circle.fill")
                            .foregroundColor(device.status.color)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button(action: { viewModel.toggleDeviceStatus(device) }) {
                        Label(
                            device.status == .running ? "Stop" : "Start",
                            systemImage: device.status == .running ? "stop.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(device.status == .running ? .red : .primary)
                }
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor))

            // Tab Picker
            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Tab Content
            switch selectedTab {
            case .overview:
                OverviewTabView(device: device)
            case .logs:
                DeviceLogsView(viewModel: viewModel, device: device)
            }
        }
    }
}

// MARK: - Overview Tab

struct OverviewTabView: View {
    let device: SimulatorDevice

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                StatCard(title: "Uptime", value: device.status == .running ? "2h 34m" : "--", icon: "clock")
                StatCard(title: "Actions", value: device.status == .running ? "1,247" : "0", icon: "bolt.fill")
                StatCard(title: "Posts", value: device.status == .running ? "23" : "0", icon: "doc.fill")
            }
            .padding(20)

            // Activity Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Activity")
                    .font(.headline)

                if device.status == .running {
                    ForEach(0..<5) { i in
                        ActivityRow(
                            action: ["Liked post", "Followed user", "Commented", "Viewed story", "Shared post"][i],
                            time: "\(i + 1)m ago"
                        )
                    }
                } else {
                    Text("Device is offline")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Device Logs View

struct DeviceLogsView: View {
    @ObservedObject var viewModel: FarmViewModel
    let device: SimulatorDevice
    @State private var filterLevel: LogEntry.LogLevel? = nil
    @State private var searchText: String = ""
    @State private var autoScroll: Bool = true

    private var filteredLogs: [LogEntry] {
        var logs = viewModel.logStreamer.logs

        if let level = filterLevel {
            logs = logs.filter { $0.level == level }
        }

        if !searchText.isEmpty {
            logs = logs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }

        return logs
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Log Controls
            HStack(spacing: 12) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                // Filter
                Menu {
                    Button("All Levels") {
                        filterLevel = nil
                    }
                    Divider()
                    ForEach([LogEntry.LogLevel.error, .warning, .info, .debug], id: \.self) { level in
                        Button {
                            filterLevel = level
                        } label: {
                            Label(level.rawValue, systemImage: level.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(filterLevel?.rawValue ?? "All")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)

                // Auto-scroll toggle
                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("Auto-scroll to latest")

                Spacer()

                // Clear button
                Button(action: {
                    viewModel.logStreamer.clearLogs()
                }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Clear logs")

                // Streaming indicator
                if viewModel.logStreamer.isStreaming {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Live")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Log List
            if filteredLogs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))

                    if device.status != .running {
                        Text("Start the simulator to view logs")
                            .foregroundColor(.secondary)
                    } else if !searchText.isEmpty || filterLevel != nil {
                        Text("No logs match your filters")
                            .foregroundColor(.secondary)
                    } else {
                        Text("Waiting for logs...")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredLogs) { log in
                                LogRowView(log: log, dateFormatter: dateFormatter)
                                    .id(log.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .onChange(of: viewModel.logStreamer.logs.count) { _, _ in
                        if autoScroll, let lastLog = filteredLogs.last {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(lastLog.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Log Row View

struct LogRowView: View {
    let log: LogEntry
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(dateFormatter.string(from: log.timestamp))
                .foregroundColor(.secondary)
                .frame(width: 85, alignment: .leading)

            // Level indicator
            Image(systemName: log.level.icon)
                .foregroundColor(log.level.color)
                .frame(width: 16)

            // Message
            Text(log.message)
                .foregroundColor(log.level == .error ? .red : (log.level == .warning ? .orange : .primary))
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.primary)

            Text(value)
                .font(.title)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct ActivityRow: View {
    let action: String
    let time: String

    var body: some View {
        HStack {
            Circle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 8, height: 8)

            Text(action)
                .font(.subheadline)

            Spacer()

            Text(time)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Device Sheet

struct AddDeviceSheet: View {
    @ObservedObject var viewModel: FarmViewModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var platform: Platform = .iOS

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Simulator")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("Device Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("iPhone 15 Pro", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Platform")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Platform", selection: $platform) {
                    ForEach(Platform.allCases, id: \.self) { p in
                        Label(p.rawValue, systemImage: p.icon).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Add") {
                    if !name.isEmpty {
                        viewModel.addDevice(name: name, platform: platform)
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - Add Account Sheet

struct AddAccountSheet: View {
    @ObservedObject var viewModel: FarmViewModel
    @Binding var isPresented: Bool
    @State private var username = ""
    @State private var platform: SocialPlatform = .instagram

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Account")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("Username")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("@username", text: $username)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Platform")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Platform", selection: $platform) {
                    ForEach(SocialPlatform.allCases, id: \.self) { p in
                        Label(p.rawValue, systemImage: p.icon).tag(p)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Add") {
                    if !username.isEmpty {
                        viewModel.addAccount(username: username, platform: platform)
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .disabled(username.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
