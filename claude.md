# Atl Project Guidelines

## Swift & SwiftUI Best Practices

### Code Style

- Use `@MainActor` for all UI-related classes and view models
- Prefer `@Observable` (iOS 17+/macOS 14+) over `ObservableObject` when possible
- Use `async/await` for all asynchronous operations
- Avoid force unwrapping (`!`) - use `guard let` or `if let` instead
- Use `Sendable` conformance for types shared across concurrency domains

### Naming Conventions

- Use descriptive names: `fetchSimulators()` not `fetch()`
- Boolean properties should read as assertions: `isRunning`, `hasError`, `canExecute`
- Action methods should be verbs: `bootSimulator()`, `captureScreenshot()`
- Factory methods use `make` prefix: `makeController()`

### Architecture

- Services are singletons accessed via `.shared`
- Keep views thin - logic belongs in view models or services
- Use dependency injection where testability matters
- Separate concerns: networking, persistence, UI state

### SwiftUI Patterns

```swift
// Prefer computed properties for derived state
var isValid: Bool {
    !name.isEmpty && email.contains("@")
}

// Use ViewBuilder for conditional content
@ViewBuilder
private var content: some View {
    if isLoading {
        ProgressView()
    } else {
        mainContent
    }
}

// Extract reusable components
struct ActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
    }
}
```

### Error Handling

- Define domain-specific error enums conforming to `LocalizedError`
- Provide meaningful `errorDescription` for user-facing errors
- Log errors with context before propagating
- Use `Result` type when errors need to be passed as values

### Concurrency

```swift
// Always specify actor isolation explicitly
@MainActor
public class ViewModel {
    // UI state here
}

// Use Task groups for parallel operations
await withTaskGroup(of: Result.self) { group in
    for item in items {
        group.addTask { await process(item) }
    }
}

// Prefer structured concurrency
let task = Task {
    try await longOperation()
}
// Can be cancelled: task.cancel()
```

### File Organization

```
Sources/
├── AtlFeature/
│   ├── Models/          # Data models
│   ├── Services/        # Business logic, networking
│   ├── Views/           # SwiftUI views
│   ├── ViewModels/      # View state management
│   └── Utilities/       # Extensions, helpers
```

## Playwright for iOS Simulator

### Architecture Overview

The system consists of:

1. **Atl** (macOS app) - Main automation interface with PlaywrightController
2. **AtlBrowser** (iOS app) - WebView-based browser running in simulator
3. **Communication Bridge** - HTTP on port 9222 between host and simulator

```
┌─────────────────┐         HTTP :9222        ┌──────────────┐
│   Atl (macOS)   │ ◄──────────────────────► │  AtlBrowser  │
│                 │                           │    (iOS)     │
│  AtlPackage/    │                           │              │
│  └─Services/    │  Commands (JSON)          │ AtlBrowser   │
│    └─Playwright │ ────────────────────────► │ Package/     │
│      Controller │                           │ └─Command    │
│                 │ ◄──────────────────────── │   Server     │
│                 │  Responses                │              │
└─────────────────┘                           └──────────────┘
```

### Development Setup (Dual-Build Process)

**IMPORTANT:** This project requires building TWO separate apps:

1. **Build & Run macOS app (Atl)**
   ```bash
   # Using xcodebuildmcp:
   session-set-defaults workspacePath=/path/to/Atl.xcworkspace scheme=Atl
   build_run_macos
   ```

2. **Build & Run iOS app (AtlBrowser)**
   ```bash
   # Using xcodebuildmcp:
   session-set-defaults workspacePath=/path/to/AtlBrowser/AtlBrowser.xcworkspace scheme=AtlBrowser simulatorId=<UDID>
   build_run_sim
   ```

3. **Verify Connection**
   ```bash
   # Check if CommandServer is listening:
   lsof -i :9222

   # Test the connection:
   curl http://localhost:9222/ping
   # Should return: {"status":"ok"}
   ```

**Troubleshooting:**
- If port 9222 isn't listening, relaunch the AtlBrowser app
- The CommandServer starts automatically when AtlBrowser launches
- Both apps must be running for automation to work

### Testing Commands via curl

```bash
# Navigate to a URL
curl -X POST http://localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"1","method":"goto","params":{"url":"https://google.com"}}'

# Fill a form field
curl -X POST http://localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"2","method":"fill","params":{"selector":"textarea[name=q]","value":"search text"}}'

# Press Enter (submits forms automatically)
curl -X POST http://localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"3","method":"press","params":{"key":"Enter"}}'

# Take a screenshot (returns base64 PNG)
curl -X POST http://localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"4","method":"screenshot","params":{}}' | jq -r '.result.data' | base64 -d > screenshot.png
```

### PlaywrightController API

```swift
public actor PlaywrightController {
    // Navigation
    func goto(_ url: String) async throws
    func reload() async throws
    func goBack() async throws
    func goForward() async throws

    // Interactions
    func click(_ selector: String) async throws
    func type(_ selector: String, text: String) async throws
    func fill(_ selector: String, value: String) async throws
    func press(_ key: String) async throws
    func hover(_ selector: String) async throws

    // Queries
    func querySelector(_ selector: String) async throws -> Element?
    func querySelectorAll(_ selector: String) async throws -> [Element]
    func waitForSelector(_ selector: String, timeout: TimeInterval) async throws
    func evaluate<T>(_ script: String) async throws -> T

    // Screenshots
    func screenshot() async throws -> Data
    func screenshot(selector: String) async throws -> Data

    // Cookies
    func saveCookies(to url: URL) async throws
    func loadCookies(from url: URL) async throws
    func deleteCookies() async throws
    func getCookies() async throws -> [HTTPCookie]

    // Lifecycle
    func launch(simulator: String?) async throws
    func close() async throws
}
```

### Communication Protocol

Commands sent as JSON over HTTP POST to simulator app:

```json
{
    "id": "uuid",
    "method": "click",
    "params": {
        "selector": "#submit-button"
    }
}
```

Responses:

```json
{
    "id": "uuid",
    "success": true,
    "result": { ... }
}
```

### copy-app Integration

Use copy-app for:
- Window screenshots: `copy-app --app "Simulator" --top`
- Accessibility tree: For element inspection outside WebView
- Keyboard input: `copy-app --type "text" --app "Simulator"`
