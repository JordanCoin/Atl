import Foundation

// MARK: - Build State Service

/// Tracks build state and ensures running apps match latest builds
@MainActor
@Observable
public class BuildStateService {
    public static let shared = BuildStateService()

    // MARK: - Types

    public enum TargetPlatform: String, Codable, CaseIterable {
        case iOSSimulator = "iOS Simulator"
        case macOS = "macOS"
    }

    public struct ProjectTarget: Identifiable, Codable {
        public var id: String { "\(workspacePath ?? projectPath ?? "unknown")-\(scheme)" }
        public let projectPath: String?
        public let workspacePath: String?
        public let scheme: String
        public let platform: TargetPlatform
        public var bundleId: String?
        public var lastBuildTime: Date?
        public var lastBuildPath: String?
        public var isRunning: Bool = false
        public var runningPID: Int32?

        public var displayName: String {
            let path = workspacePath ?? projectPath ?? "Unknown"
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return "\(name) (\(scheme))"
        }
    }

    public struct BuildResult {
        public let success: Bool
        public let appPath: String?
        public let bundleId: String?
        public let buildTime: Date
        public let logs: String
        public let errors: [String]
        public let warnings: [String]
    }

    public struct RunResult {
        public let success: Bool
        public let pid: Int32?
        public let logs: String
        public let launchTime: Date
    }

    // MARK: - State

    public var trackedTargets: [ProjectTarget] = []
    public var currentTarget: ProjectTarget?
    public var buildLogs: [String] = []
    public var isBuilding = false
    public var isLaunching = false

    private init() {
        loadTrackedTargets()
    }

    // MARK: - Target Management

    public func addTarget(
        projectPath: String? = nil,
        workspacePath: String? = nil,
        scheme: String,
        platform: TargetPlatform
    ) -> ProjectTarget {
        let target = ProjectTarget(
            projectPath: projectPath,
            workspacePath: workspacePath,
            scheme: scheme,
            platform: platform
        )

        if !trackedTargets.contains(where: { $0.id == target.id }) {
            trackedTargets.append(target)
            saveTrackedTargets()
        }

        return target
    }

    public func removeTarget(_ target: ProjectTarget) {
        trackedTargets.removeAll { $0.id == target.id }
        saveTrackedTargets()
    }

    public func setCurrentTarget(_ target: ProjectTarget) {
        currentTarget = target
    }

    // MARK: - Build State Detection

    /// Check if app binary is newer than running app
    public func isRunningAppStale(_ target: ProjectTarget) async -> Bool {
        guard let appPath = target.lastBuildPath else { return true }

        // Get modification time of app bundle
        let appURL = URL(fileURLWithPath: appPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: appURL.path),
              let modTime = attrs[.modificationDate] as? Date else {
            return true
        }

        // If we have a recorded build time, compare
        if let buildTime = target.lastBuildTime {
            return modTime > buildTime
        }

        return true
    }

    /// Check if an app is currently running
    public func isAppRunning(_ target: ProjectTarget) async -> Bool {
        guard let bundleId = target.bundleId else { return false }

        switch target.platform {
        case .macOS:
            return await isAppRunningMacOS(bundleId: bundleId)
        case .iOSSimulator:
            return await isAppRunningSimulator(bundleId: bundleId)
        }
    }

    private func isAppRunningMacOS(bundleId: String) async -> Bool {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", bundleId]
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

    private func isAppRunningSimulator(bundleId: String) async -> Bool {
        // Use simctl to check if app is running
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "get_app_container", "booted", bundleId]
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

    // MARK: - Build Operations

    /// Build the target and return result
    public func build(_ target: ProjectTarget) async -> BuildResult {
        isBuilding = true
        defer { isBuilding = false }

        let startTime = Date()
        var logs: [String] = []
        var errors: [String] = []
        var warnings: [String] = []

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")

        var args: [String] = []

        if let workspace = target.workspacePath {
            args += ["-workspace", workspace]
        } else if let project = target.projectPath {
            args += ["-project", project]
        }

        args += ["-scheme", target.scheme]

        switch target.platform {
        case .iOSSimulator:
            args += ["-destination", "platform=iOS Simulator,name=iPhone 17"]
        case .macOS:
            args += ["-destination", "platform=macOS"]
        }

        args += ["build"]

        process.arguments = args
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        logs.append("🔨 Building \(target.displayName)...")
        logs.append("Command: xcodebuild \(args.joined(separator: " "))")

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let output = String(data: outputData, encoding: .utf8) {
                logs.append(output)

                // Parse warnings and errors
                for line in output.components(separatedBy: .newlines) {
                    if line.contains("warning:") {
                        warnings.append(line)
                    } else if line.contains("error:") {
                        errors.append(line)
                    }
                }
            }

            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                logs.append("STDERR: \(errorOutput)")
            }

            let success = process.terminationStatus == 0

            if success {
                logs.append("✅ Build succeeded")
            } else {
                logs.append("❌ Build failed with exit code \(process.terminationStatus)")
            }

            // Get app path
            let appPath = await getAppPath(target)
            let bundleId = appPath != nil ? await getBundleId(appPath: appPath!) : nil

            buildLogs = logs

            // Update target state
            if var updatedTarget = trackedTargets.first(where: { $0.id == target.id }) {
                updatedTarget.lastBuildTime = startTime
                updatedTarget.lastBuildPath = appPath
                updatedTarget.bundleId = bundleId
                if let index = trackedTargets.firstIndex(where: { $0.id == target.id }) {
                    trackedTargets[index] = updatedTarget
                }
                saveTrackedTargets()
            }

            return BuildResult(
                success: success,
                appPath: appPath,
                bundleId: bundleId,
                buildTime: startTime,
                logs: logs.joined(separator: "\n"),
                errors: errors,
                warnings: warnings
            )

        } catch {
            logs.append("❌ Build error: \(error.localizedDescription)")
            buildLogs = logs

            return BuildResult(
                success: false,
                appPath: nil,
                bundleId: nil,
                buildTime: startTime,
                logs: logs.joined(separator: "\n"),
                errors: [error.localizedDescription],
                warnings: []
            )
        }
    }

    private func getAppPath(_ target: ProjectTarget) async -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")

        var args: [String] = []

        if let workspace = target.workspacePath {
            args += ["-workspace", workspace]
        } else if let project = target.projectPath {
            args += ["-project", project]
        }

        args += ["-scheme", target.scheme, "-showBuildSettings"]

        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Parse BUILT_PRODUCTS_DIR and PRODUCT_NAME
            var builtProductsDir: String?
            var productName: String?

            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("BUILT_PRODUCTS_DIR = ") {
                    builtProductsDir = String(trimmed.dropFirst("BUILT_PRODUCTS_DIR = ".count))
                } else if trimmed.hasPrefix("PRODUCT_NAME = ") {
                    productName = String(trimmed.dropFirst("PRODUCT_NAME = ".count))
                }
            }

            if let dir = builtProductsDir, let name = productName {
                return "\(dir)/\(name).app"
            }

        } catch {
            print("Failed to get app path: \(error)")
        }

        return nil
    }

    private func getBundleId(appPath: String) async -> String? {
        let plistPath = "\(appPath)/Contents/Info.plist"

        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else {

            // Try iOS app structure
            let iosPlistPath = "\(appPath)/Info.plist"
            guard let iosData = FileManager.default.contents(atPath: iosPlistPath),
                  let iosPlist = try? PropertyListSerialization.propertyList(from: iosData, format: nil) as? [String: Any],
                  let iosBundleId = iosPlist["CFBundleIdentifier"] as? String else {
                return nil
            }
            return iosBundleId
        }

        return bundleId
    }

    // MARK: - Launch Operations

    /// Ensure latest build is running, rebuild and relaunch if needed
    public func ensureLatestRunning(_ target: ProjectTarget) async -> RunResult {
        // Check if running app is stale
        let stale = await isRunningAppStale(target)
        let running = await isAppRunning(target)

        if stale || !running {
            // Build first
            let buildResult = await build(target)

            if !buildResult.success {
                return RunResult(
                    success: false,
                    pid: nil,
                    logs: "Build failed: \(buildResult.logs)",
                    launchTime: Date()
                )
            }

            // Stop old app if running
            if running {
                await stopApp(target)
            }

            // Launch new build
            return await launchApp(target)
        }

        return RunResult(
            success: true,
            pid: target.runningPID,
            logs: "App already running with latest build",
            launchTime: Date()
        )
    }

    public func launchApp(_ target: ProjectTarget) async -> RunResult {
        isLaunching = true
        defer { isLaunching = false }

        guard let appPath = target.lastBuildPath else {
            return RunResult(success: false, pid: nil, logs: "No app path", launchTime: Date())
        }

        switch target.platform {
        case .macOS:
            return await launchMacOSApp(appPath: appPath)
        case .iOSSimulator:
            return await launchSimulatorApp(target: target)
        }
    }

    private func launchMacOSApp(appPath: String) async -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath]

        do {
            try process.run()
            process.waitUntilExit()

            return RunResult(
                success: process.terminationStatus == 0,
                pid: nil,
                logs: "Launched macOS app",
                launchTime: Date()
            )
        } catch {
            return RunResult(
                success: false,
                pid: nil,
                logs: "Failed to launch: \(error)",
                launchTime: Date()
            )
        }
    }

    private func launchSimulatorApp(target: ProjectTarget) async -> RunResult {
        guard let bundleId = target.bundleId else {
            return RunResult(success: false, pid: nil, logs: "No bundle ID", launchTime: Date())
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "launch", "booted", bundleId]

        do {
            try process.run()
            process.waitUntilExit()

            return RunResult(
                success: process.terminationStatus == 0,
                pid: nil,
                logs: "Launched simulator app",
                launchTime: Date()
            )
        } catch {
            return RunResult(
                success: false,
                pid: nil,
                logs: "Failed to launch: \(error)",
                launchTime: Date()
            )
        }
    }

    public func stopApp(_ target: ProjectTarget) async {
        guard let bundleId = target.bundleId else { return }

        switch target.platform {
        case .macOS:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-f", bundleId]
            try? process.run()
            process.waitUntilExit()

        case .iOSSimulator:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "terminate", "booted", bundleId]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Persistence

    private let storageKey = "build_state_tracked_targets"

    private func saveTrackedTargets() {
        if let data = try? JSONEncoder().encode(trackedTargets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadTrackedTargets() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let targets = try? JSONDecoder().decode([ProjectTarget].self, from: data) {
            trackedTargets = targets
        }
    }
}
