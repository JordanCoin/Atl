import SwiftUI
import AtlFeature

@main
struct AtlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Devices") {
                Button("Add Simulator...") {
                    NotificationCenter.default.post(name: .addDevice, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Refresh All") {
                    NotificationCenter.default.post(name: .refreshDevices, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra("Atl", systemImage: "iphone.gen3") {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

struct MenuBarView: View {
    var body: some View {
        VStack(spacing: 4) {
            Label("4 Devices", systemImage: "iphone.gen3")
            Label("1 Running", systemImage: "play.circle.fill")
        }
        .padding(.vertical, 4)

        Divider()

        Button("Open Atl") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        .keyboardShortcut("o", modifiers: [.command])

        Divider()

        Button("Quit Atl") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}

extension Notification.Name {
    static let addDevice = Notification.Name("addDevice")
    static let refreshDevices = Notification.Name("refreshDevices")
}
