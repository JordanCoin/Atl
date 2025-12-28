import Foundation

// MARK: - Tool Executor

/// Central executor for all automation tools (axe, copy-app, simctl, etc.)
/// DRY implementation - all tool execution goes through here.
public enum ToolExecutor {

    // MARK: - Execution Result

    public struct Result {
        public let success: Bool
        public let output: String
        public let error: String
        public let exitCode: Int32
        public let durationMs: Int

        public static func failure(_ message: String) -> Result {
            Result(success: false, output: "", error: message, exitCode: -1, durationMs: 0)
        }
    }

    // MARK: - Generic Process Runner

    private static func run(
        executable: String,
        arguments: [String],
        captureOutput: Bool = false
    ) async -> Result {
        let start = Date()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if captureOutput {
            process.standardOutput = outputPipe
            process.standardError = errorPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            process.waitUntilExit()

            let durationMs = Int(Date().timeIntervalSince(start) * 1000)

            var output = ""
            var errorOutput = ""

            if captureOutput {
                output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }

            return Result(
                success: process.terminationStatus == 0,
                output: output,
                error: errorOutput,
                exitCode: process.terminationStatus,
                durationMs: durationMs
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - axe (iOS Simulator)

    public enum Axe {
        private static let path = "/opt/homebrew/bin/axe"

        /// Get UI hierarchy as JSON
        public static func describeUI(udid: String) async -> Result {
            await run(executable: path, arguments: ["describe-ui", "--udid", udid], captureOutput: true)
        }

        /// Tap at coordinates
        public static func tap(udid: String, x: Int, y: Int) async -> Result {
            await run(executable: path, arguments: ["tap", "--udid", udid, "-x", "\(x)", "-y", "\(y)"])
        }

        /// Tap by accessibility ID
        public static func tap(udid: String, id: String) async -> Result {
            await run(executable: path, arguments: ["tap", "--udid", udid, "--id", id])
        }

        /// Tap by label
        public static func tap(udid: String, label: String) async -> Result {
            await run(executable: path, arguments: ["tap", "--udid", udid, "--label", label])
        }

        /// Type text
        public static func type(udid: String, text: String) async -> Result {
            await run(executable: path, arguments: ["type", "--udid", udid, text])
        }

        /// Swipe gesture
        public static func swipe(udid: String, fromX: Int, fromY: Int, toX: Int, toY: Int) async -> Result {
            await run(executable: path, arguments: [
                "swipe", "--udid", udid,
                "--from", "\(fromX),\(fromY)",
                "--to", "\(toX),\(toY)"
            ])
        }

        /// Preset gesture (scroll-up, scroll-down, etc.)
        public static func gesture(udid: String, preset: String) async -> Result {
            await run(executable: path, arguments: ["gesture", "--udid", udid, preset])
        }

        /// Hardware button (home, lock, siri, etc.)
        public static func button(udid: String, name: String) async -> Result {
            await run(executable: path, arguments: ["button", "--udid", udid, name])
        }

        /// Screenshot to file
        public static func screenshot(udid: String, outputPath: String) async -> Result {
            await run(executable: path, arguments: ["screenshot", "--udid", udid, outputPath])
        }

        /// Screenshot to Data
        public static func screenshotData(udid: String) async -> Data? {
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("axe_screenshot_\(UUID().uuidString).png")

            let result = await screenshot(udid: udid, outputPath: tempPath.path)

            guard result.success else { return nil }
            defer { try? FileManager.default.removeItem(at: tempPath) }

            return try? Data(contentsOf: tempPath)
        }

        /// List simulators
        public static func listSimulators() async -> Result {
            await run(executable: path, arguments: ["list-simulators"], captureOutput: true)
        }
    }

    // MARK: - copy-app (macOS)

    public enum CopyApp {
        private static let path = "/opt/homebrew/bin/copy-app"

        /// Click at coordinates
        public static func click(appName: String, x: Int, y: Int, windowTitle: String? = nil) async -> Result {
            var args = [appName, "--click", "\(x),\(y)"]
            if let title = windowTitle {
                args += ["-t", title]
            }
            return await run(executable: path, arguments: args)
        }

        /// Press button by name
        public static func press(appName: String, buttonName: String, windowTitle: String? = nil) async -> Result {
            var args = [appName, "--press", buttonName]
            if let title = windowTitle {
                args += ["-t", title]
            }
            return await run(executable: path, arguments: args)
        }

        /// Type text
        public static func type(appName: String, text: String, windowTitle: String? = nil) async -> Result {
            var args = [appName, "--type", text]
            if let title = windowTitle {
                args += ["-t", title]
            }
            return await run(executable: path, arguments: args)
        }

        /// Key combination (e.g., "cmd+n")
        public static func keys(appName: String, combo: String, windowTitle: String? = nil) async -> Result {
            var args = [appName, "--keys", combo]
            if let title = windowTitle {
                args += ["-t", title]
            }
            return await run(executable: path, arguments: args)
        }

        /// Find/navigate to text
        public static func find(appName: String, text: String, windowTitle: String? = nil) async -> Result {
            var args = [appName, "--find", text]
            if let title = windowTitle {
                args += ["-t", title]
            }
            return await run(executable: path, arguments: args)
        }
    }

    // MARK: - simctl (iOS Simulator system)

    public enum Simctl {
        private static let xcrun = "/usr/bin/xcrun"

        /// List devices as JSON
        public static func listDevices() async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "list", "devices", "-j"], captureOutput: true)
        }

        /// Get booted simulator UDID
        public static func bootedUDID() async -> String? {
            let result = await listDevices()
            guard result.success,
                  let data = result.output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [String: [[String: Any]]] else {
                return nil
            }

            for (_, deviceList) in devices {
                for device in deviceList {
                    if let state = device["state"] as? String,
                       state == "Booted",
                       let udid = device["udid"] as? String {
                        return udid
                    }
                }
            }
            return nil
        }

        /// Screenshot
        public static func screenshot(udid: String, outputPath: String) async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "io", udid, "screenshot", outputPath])
        }

        /// Screenshot to Data
        public static func screenshotData(udid: String) async -> Data? {
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("simctl_screenshot_\(UUID().uuidString).png")

            let result = await screenshot(udid: udid, outputPath: tempPath.path)

            guard result.success else { return nil }
            defer { try? FileManager.default.removeItem(at: tempPath) }

            return try? Data(contentsOf: tempPath)
        }

        /// Launch app
        public static func launch(udid: String, bundleId: String) async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "launch", udid, bundleId])
        }

        /// Terminate app
        public static func terminate(udid: String, bundleId: String) async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "terminate", udid, bundleId])
        }

        /// Install app
        public static func install(udid: String, appPath: String) async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "install", udid, appPath])
        }

        /// Boot simulator
        public static func boot(udid: String) async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "boot", udid])
        }

        /// Shutdown simulator
        public static func shutdown(udid: String) async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "shutdown", udid])
        }

        /// Get app container path
        public static func appContainer(udid: String, bundleId: String) async -> Result {
            await run(executable: xcrun, arguments: ["simctl", "get_app_container", udid, bundleId], captureOutput: true)
        }
    }

    // MARK: - screencapture (macOS)

    public enum ScreenCapture {
        /// Capture entire screen
        public static func captureScreen(outputPath: String) async -> Result {
            await run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-o", outputPath])
        }

        /// Capture to Data
        public static func captureData() async -> Data? {
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("macos_screenshot_\(UUID().uuidString).png")

            let result = await captureScreen(outputPath: tempPath.path)

            guard result.success else { return nil }
            defer { try? FileManager.default.removeItem(at: tempPath) }

            return try? Data(contentsOf: tempPath)
        }

        /// Capture specific window by ID
        public static func captureWindow(windowId: Int, outputPath: String) async -> Result {
            await run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-l", "\(windowId)", outputPath])
        }
    }
}
