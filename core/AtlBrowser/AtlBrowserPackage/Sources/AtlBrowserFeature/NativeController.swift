import Foundation

// MARK: - Native App Support (Stub)
//
// NOTE: Native app automation requires XCTest/XCUIApplication which is ONLY
// available in UI Test bundles, not regular iOS apps.
//
// This is a stub implementation that returns "not implemented" errors.
// Full native app support requires architectural changes:
// 1. Create a UI Test target
// 2. Have the command server communicate with the test runner
// 3. Use a test runner architecture (like Appium)
//
// See: https://github.com/JordanCoin/Atl/issues/new (file an issue to discuss)
//
// Types (AppState, FindBy, FindAction, FindResult, etc.) are defined in CommandServer.swift

// MARK: - Additional Native Types

struct NativeElement: Codable {
    let ref: String
    let type: String
    let label: String?
    let value: String?
    let identifier: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isHittable: Bool
    let isEnabled: Bool
}

struct NativeSnapshot: Codable {
    let elements: [NativeElement]
    let count: Int
    let bundleId: String?
}

// MARK: - Errors

enum NativeError: Error, LocalizedError {
    case notImplemented(String)
    case noAppOpen
    case elementNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .notImplemented(let feature):
            return "Native app automation not yet implemented: \(feature). XCTest APIs require a UI Test target. See NATIVE-APPS-TODO.md for architecture details."
        case .noAppOpen:
            return "No app is currently open"
        case .elementNotFound(let ref):
            return "Element not found: \(ref)"
        }
    }
}

// MARK: - NativeController (Stub)

/// Stub controller for native iOS app automation
/// 
/// Full implementation requires XCTest which is only available in UI Test bundles.
/// This stub allows the browser functionality to build and work while native
/// app support is being architected.
@MainActor
final class NativeController {
    
    private(set) var currentBundleId: String?
    
    // MARK: - App Lifecycle (Stubs)
    
    func openApp(bundleId: String) async throws -> AppState {
        throw NativeError.notImplemented("openApp")
    }
    
    func closeApp(bundleId: String? = nil) async throws {
        throw NativeError.notImplemented("closeApp")
    }
    
    func appState() -> AppState {
        return AppState(bundleId: nil, state: .none)
    }
    
    // MARK: - Accessibility Snapshot (Stub)
    
    func snapshot(interactiveOnly: Bool = false, maxDepth: Int? = nil) async throws -> SnapshotResult {
        throw NativeError.notImplemented("snapshot")
    }
    
    // MARK: - Ref-Based Interactions (Stubs)
    
    func tapRef(ref: String) async throws {
        throw NativeError.notImplemented("tapRef")
    }
    
    func fillRef(ref: String, text: String) async throws {
        throw NativeError.notImplemented("fillRef")
    }
    
    func focusRef(ref: String) async throws {
        throw NativeError.notImplemented("focusRef")
    }
    
    // MARK: - Semantic Find (Stub)
    
    func find(text: String, by: FindBy = .any, action: FindAction = .exists, value: String? = nil) async throws -> FindResult {
        throw NativeError.notImplemented("find")
    }
    
    // MARK: - Touch Gestures (Stubs)
    
    func tap(at point: CGPoint) async throws {
        throw NativeError.notImplemented("tap coordinates in native mode")
    }
    
    func longPress(at point: CGPoint, duration: Double) async throws {
        throw NativeError.notImplemented("longPress in native mode")
    }
    
    func swipe(direction: String, distance: Double, duration: Double) async throws {
        throw NativeError.notImplemented("swipe in native mode")
    }
    
    func swipe(from: CGPoint, to: CGPoint, duration: Double) async throws {
        throw NativeError.notImplemented("swipe coordinates in native mode")
    }
    
    func pinch(scale: Double, duration: Double) async throws {
        throw NativeError.notImplemented("pinch in native mode")
    }
    
    func screenshot() async throws -> Data {
        throw NativeError.notImplemented("screenshot in native mode")
    }
}
