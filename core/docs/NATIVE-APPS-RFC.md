# RFC: Native App Automation for ATL

> Extend ATL to control native iOS apps, not just the browser.

## Current Architecture

```
┌─────────────────────────────────────────────┐
│  AtlBrowser.app (XCTest Host)               │
│  ┌───────────────────────────────────────┐  │
│  │  CommandServer (HTTP :9222)           │  │
│  │           ↓                           │  │
│  │  BrowserController                    │  │
│  │           ↓                           │  │
│  │  WKWebView → DOM → JavaScript         │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## Proposed Architecture

```
┌─────────────────────────────────────────────┐
│  AtlBrowser.app (XCTest Host)               │
│  ┌───────────────────────────────────────┐  │
│  │  CommandServer (HTTP :9222)           │  │
│  │           ↓                           │  │
│  │  ┌─────────────┬─────────────────┐    │  │
│  │  │ Browser     │ Native          │    │  │
│  │  │ Controller  │ Controller      │    │  │
│  │  │     ↓       │      ↓          │    │  │
│  │  │ WKWebView   │ XCUIApplication │    │  │
│  │  │ (DOM)       │ (Accessibility) │    │  │
│  │  └─────────────┴─────────────────┘    │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## New Commands

### App Lifecycle

```bash
# Open/activate an app
POST /command {"method":"openApp","params":{"bundleId":"com.apple.Preferences"}}
# → {"success":true,"result":{"bundleId":"com.apple.Preferences","state":"running"}}

# Close an app
POST /command {"method":"closeApp","params":{"bundleId":"com.apple.Preferences"}}

# Get current app state
POST /command {"method":"appState"}
# → {"success":true,"result":{"bundleId":"com.apple.Preferences","mode":"native"}}

# Switch back to browser mode
POST /command {"method":"openBrowser"}
```

### Accessibility Snapshot

```bash
# Get accessibility tree (native mode)
POST /command {"method":"snapshot","params":{"interactiveOnly":true}}
# → {
#     "success": true,
#     "result": {
#       "count": 47,
#       "elements": [
#         {"ref":"e1","type":"button","label":"Back","x":20,"y":60,"width":44,"height":44},
#         {"ref":"e2","type":"staticText","label":"Settings","x":150,"y":60},
#         {"ref":"e3","type":"cell","label":"Wi-Fi","x":0,"y":120,"width":390,"height":44},
#         ...
#       ]
#     }
#   }
```

### Interactions (work for both modes)

```bash
# Tap by ref (native) or mark label (browser)
POST /command {"method":"tapRef","params":{"ref":"e3"}}

# Existing coordinate-based commands work for both:
POST /command {"method":"tap","params":{"x":200,"y":150}}
POST /command {"method":"swipe","params":{"direction":"up"}}
POST /command {"method":"pinch","params":{"scale":2.0}}

# Type text (uses focused element)
POST /command {"method":"type","params":{"text":"hello"}}
```

### Semantic Find (new!)

```bash
# Find element by text and perform action
POST /command {"method":"find","params":{"text":"Wi-Fi","action":"tap"}}
POST /command {"method":"find","params":{"label":"Email","action":"fill","value":"test@example.com"}}
POST /command {"method":"find","params":{"text":"Submit","action":"exists"}}
# → {"success":true,"result":{"found":true,"ref":"e7"}}
```

## Implementation Plan

### Phase 1: Native Controller (MVP)
- [ ] Add `NativeController` class using XCUIApplication
- [ ] Implement `openApp`, `closeApp`, `appState`
- [ ] Implement `snapshot` for accessibility tree
- [ ] Implement `tapRef` for ref-based tapping
- [ ] Route commands based on current mode

### Phase 2: Unified Commands
- [ ] Make `tap`, `swipe`, `pinch` work in both modes
- [ ] Add `screenshot` for native apps
- [ ] Add semantic `find` command

### Phase 3: Hybrid Flows
- [ ] Support switching between browser and native in same session
- [ ] Example: Open Safari (native) → Navigate to URL → Control WebView
- [ ] Example: Browser flow → Native app deeplink → Back to browser

## Code Changes

### New File: `NativeController.swift`

```swift
import XCTest

@MainActor
final class NativeController {
    private var currentApp: XCUIApplication?
    private var currentBundleId: String?
    
    func openApp(_ bundleId: String) async throws {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.activate()
        _ = app.waitForExistence(timeout: 5)
        currentApp = app
        currentBundleId = bundleId
    }
    
    func closeApp(_ bundleId: String? = nil) {
        let target = bundleId ?? currentBundleId
        if let target = target {
            let app = XCUIApplication(bundleIdentifier: target)
            app.terminate()
        }
        if bundleId == nil || bundleId == currentBundleId {
            currentApp = nil
            currentBundleId = nil
        }
    }
    
    func snapshot(interactiveOnly: Bool = false) -> [AccessibilityElement] {
        guard let app = currentApp else { return [] }
        
        var elements: [AccessibilityElement] = []
        var index = 0
        
        let query = app.descendants(matching: .any)
        for element in query.allElementsBoundByIndex {
            if interactiveOnly && !element.isHittable { continue }
            
            let frame = element.frame
            elements.append(AccessibilityElement(
                ref: "e\(index)",
                type: String(describing: element.elementType),
                label: element.label,
                value: element.value as? String,
                identifier: element.identifier,
                x: Int(frame.minX),
                y: Int(frame.minY),
                width: Int(frame.width),
                height: Int(frame.height),
                isHittable: element.isHittable
            ))
            index += 1
        }
        
        return elements
    }
    
    func tapRef(_ ref: String) async throws {
        guard let app = currentApp else {
            throw NativeError.noActiveApp
        }
        
        guard let index = parseRef(ref) else {
            throw NativeError.invalidRef(ref)
        }
        
        let query = app.descendants(matching: .any)
        let elements = query.allElementsBoundByIndex
        
        guard index < elements.count else {
            throw NativeError.refNotFound(ref)
        }
        
        elements[index].tap()
    }
    
    func find(text: String, action: String, value: String? = nil) async throws -> FindResult {
        guard let app = currentApp else {
            throw NativeError.noActiveApp
        }
        
        // Search by label, value, or identifier
        let predicate = NSPredicate(format: 
            "label CONTAINS[cd] %@ OR value CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@",
            text, text, text
        )
        let query = app.descendants(matching: .any).matching(predicate)
        
        guard let element = query.allElementsBoundByIndex.first else {
            return FindResult(found: false)
        }
        
        switch action {
        case "tap", "click":
            element.tap()
        case "fill":
            element.tap()
            if let value = value {
                element.typeText(value)
            }
        case "exists":
            break // just return found status
        default:
            break
        }
        
        return FindResult(found: true, ref: "e0") // TODO: track actual ref
    }
    
    private func parseRef(_ ref: String) -> Int? {
        guard ref.hasPrefix("e") else { return nil }
        return Int(ref.dropFirst())
    }
}

struct AccessibilityElement: Codable {
    let ref: String
    let type: String
    let label: String
    let value: String?
    let identifier: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let isHittable: Bool
}

struct FindResult: Codable {
    let found: Bool
    var ref: String?
}

enum NativeError: Error {
    case noActiveApp
    case invalidRef(String)
    case refNotFound(String)
}
```

### CommandServer Changes

```swift
// Add to CommandServer.swift

private var nativeController: NativeController?
private var mode: AutomationMode = .browser

enum AutomationMode {
    case browser
    case native
}

// In handleCommand:
case "openApp":
    if let bundleId = command.params?["bundleId"] as? String {
        if nativeController == nil {
            nativeController = NativeController()
        }
        try await nativeController?.openApp(bundleId)
        mode = .native
        result = ["bundleId": bundleId, "mode": "native"]
    }

case "openBrowser":
    mode = .browser
    result = ["mode": "browser"]

case "snapshot":
    if mode == .native {
        let interactiveOnly = command.params?["interactiveOnly"] as? Bool ?? false
        let elements = nativeController?.snapshot(interactiveOnly: interactiveOnly) ?? []
        result = ["count": elements.count, "elements": elements.map { ... }]
    } else {
        // existing browser markElements logic
    }

case "tapRef":
    if let ref = command.params?["ref"] as? String {
        try await nativeController?.tapRef(ref)
        result = ["tapped": ref]
    }

case "find":
    if let text = command.params?["text"] as? String {
        let action = command.params?["action"] as? String ?? "exists"
        let value = command.params?["value"] as? String
        let findResult = try await nativeController?.find(text: text, action: action, value: value)
        result = ["found": findResult?.found ?? false, "ref": findResult?.ref]
    }
```

## Example Flows

### Native App Settings

```bash
# Open Settings app
curl -X POST localhost:9222/command -d '{"method":"openApp","params":{"bundleId":"com.apple.Preferences"}}'

# Get elements
curl -X POST localhost:9222/command -d '{"method":"snapshot","params":{"interactiveOnly":true}}'

# Tap Wi-Fi
curl -X POST localhost:9222/command -d '{"method":"find","params":{"text":"Wi-Fi","action":"tap"}}'

# Or by ref
curl -X POST localhost:9222/command -d '{"method":"tapRef","params":{"ref":"e5"}}'
```

### Hybrid: Browser + Native

```bash
# Start in browser
curl -X POST localhost:9222/command -d '{"method":"goto","params":{"url":"https://example.com"}}'

# Link opens native app (e.g., App Store)
# Switch to native mode
curl -X POST localhost:9222/command -d '{"method":"openApp","params":{"bundleId":"com.apple.AppStore"}}'

# Interact with native app
curl -X POST localhost:9222/command -d '{"method":"snapshot"}'
curl -X POST localhost:9222/command -d '{"method":"find","params":{"text":"Get","action":"tap"}}'

# Switch back to browser
curl -X POST localhost:9222/command -d '{"method":"openBrowser"}'
```

## Compatibility

- **Existing browser commands** continue to work unchanged
- **New native commands** only activate when `openApp` is called
- **Shared commands** (`tap`, `swipe`, `pinch`, `screenshot`) work in both modes
- **OpenAPI spec** extended with new commands

## Timeline

- Phase 1 (MVP): ~2-3 days
- Phase 2 (Unified): ~1-2 days  
- Phase 3 (Hybrid): ~1 day

## Open Questions

1. Should `snapshot` and `markElements` be unified or separate commands?
2. Should refs be `@e5` (like agent-device) or just `e5` or `5`?
3. Do we need explicit mode switching or auto-detect based on command?
4. Should the browser be "just another app" or special-cased?

---

*This RFC is a starting point for discussion. Implementation details may change.*
