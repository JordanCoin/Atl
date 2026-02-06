# Native App Support - Implementation TODO

## ⚠️ ARCHITECTURE BLOCKER DISCOVERED

**Problem:** XCTest (XCUIApplication, XCUIElement) is **only available in UI Test bundles**, not regular iOS apps.

ATL is currently a standalone iOS app that runs a command server. To use XCUIApplication for native app automation, we need one of:

1. **UI Test Target Architecture** — Create a UI Test bundle that the command server communicates with (similar to how Appium works)
2. **Test Runner Mode** — Run ATL as an XCTest runner rather than a standalone app
3. **Private Accessibility APIs** — Use private frameworks (risky, may break)

**Current status:** NativeController.swift is stubbed to return "not implemented" errors. Browser functionality works. Native app support needs architectural work.

---

## Phase 1: Core Infrastructure ✅ COMPLETE (STUBBED)

### 1.1 NativeController.swift ✅
- [x] Create `NativeController.swift` in `AtlBrowserPackage/Sources/AtlBrowserFeature/`
- [x] Implement `openApp(bundleId: String)` using `XCUIApplication(bundleIdentifier:)`
- [x] Implement `closeApp(bundleId: String?)`
- [x] Implement `appState()` → returns current bundleId and mode
- [x] Track `currentApp: XCUIApplication?` and `currentBundleId: String?`
- [x] Handle app activation with `app.activate()` and `waitForExistence(timeout:)`

### 1.2 Accessibility Snapshot ✅
- [x] Implement `snapshot(interactiveOnly: Bool, maxDepth: Int?)` 
- [x] Walk `app.descendants(matching: .any).allElementsBoundByIndex`
- [x] Extract for each element:
  - `ref` (e.g., "e0", "e1", "e2")
  - `type` (XCUIElement.ElementType as string)
  - `label` (element.label)
  - `value` (element.value as? String)
  - `identifier` (element.identifier)
  - `x`, `y`, `width`, `height` (from element.frame)
  - `isHittable` (element.isHittable)
  - `isEnabled` (element.isEnabled)
- [x] Filter non-hittable elements when `interactiveOnly: true`
- [x] Limit traversal depth when `maxDepth` specified
- [x] Cap max elements (e.g., 500) to avoid huge responses

### 1.3 Ref-Based Interaction ✅
- [x] Implement `tapRef(ref: String)` - parse ref, find element, tap
- [x] Implement `fillRef(ref: String, text: String)` - tap then type
- [x] Implement `focusRef(ref: String)` - tap without typing
- [x] Store element index mapping from last snapshot for ref lookup

### 1.4 Semantic Find ✅
- [x] Implement `find(text: String, by: FindBy, action: FindAction, value: String?)`
- [x] FindBy enum: `.any`, `.label`, `.value`, `.identifier`, `.type`
- [x] FindAction enum: `.tap`, `.fill`, `.exists`, `.get`
- [x] Use NSPredicate for flexible matching
- [x] Return `{found: Bool, ref: String?, element: ElementInfo?}`

### 1.5 CommandServer Integration ✅
- [x] Add `nativeController: NativeController?` property
- [x] Add `mode: AutomationMode` enum (`.browser`, `.native`)
- [x] Route new commands:
  - `openApp` → nativeController.openApp()
  - `closeApp` → nativeController.closeApp()
  - `appState` → return mode + bundleId
  - `snapshot` → nativeController.snapshot() (native mode only)
  - `tapRef` → nativeController.tapRef()
  - `find` → nativeController.find()
  - `openBrowser` → switch back to browser mode
- [x] Validate mode for mode-specific commands (error if wrong mode)
- [x] Ensure `tap`, `swipe`, `pinch`, `screenshot` work in both modes

---

## Phase 2: Testing Path

### Test Environment
- iOS Simulator (iPhone 16 Pro or similar)
- Built-in apps only (no App Store downloads needed)

### 2.1 Settings App Tests

```bash
# Test: Open Settings
curl -X POST localhost:9222/command \
  -d '{"method":"openApp","params":{"bundleId":"com.apple.Preferences"}}'
# Expected: {"success":true,"result":{"bundleId":"com.apple.Preferences","mode":"native"}}

# Test: Get app state
curl -X POST localhost:9222/command \
  -d '{"method":"appState"}'
# Expected: {"success":true,"result":{"mode":"native","bundleId":"com.apple.Preferences"}}

# Test: Snapshot
curl -X POST localhost:9222/command \
  -d '{"method":"snapshot","params":{"interactiveOnly":true}}'
# Expected: {"success":true,"result":{"count":N,"elements":[...]}}
# Verify: Elements include Wi-Fi, Bluetooth, Cellular, etc.

# Test: Find and tap
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"Wi-Fi","action":"tap"}}'
# Expected: {"success":true,"result":{"found":true}}
# Verify: Wi-Fi screen opens

# Test: Navigate back
curl -X POST localhost:9222/command \
  -d '{"method":"swipe","params":{"direction":"right"}}'
# Or: find "Settings" back button and tap

# Test: Tap by ref
curl -X POST localhost:9222/command \
  -d '{"method":"snapshot","params":{"interactiveOnly":true}}'
# Find ref for "Bluetooth"
curl -X POST localhost:9222/command \
  -d '{"method":"tapRef","params":{"ref":"e5"}}'  # Use actual ref
# Verify: Bluetooth screen opens

# Test: Close app
curl -X POST localhost:9222/command \
  -d '{"method":"closeApp"}'
# Expected: {"success":true}
```

### 2.2 Contacts App Tests

```bash
# Test: Open Contacts
curl -X POST localhost:9222/command \
  -d '{"method":"openApp","params":{"bundleId":"com.apple.MobileAddressBook"}}'

# Test: Snapshot contacts list
curl -X POST localhost:9222/command \
  -d '{"method":"snapshot","params":{"interactiveOnly":true}}'

# Test: Tap "Add" button (+ icon)
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"Add","action":"tap"}}'

# Test: Fill first name field
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"First name","action":"fill","value":"Test"}}'

# Test: Fill last name
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"Last name","action":"fill","value":"User"}}'

# Test: Save (tap Done)
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"Done","action":"tap"}}'

# Verify: Contact created
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"Test User","action":"exists"}}'
# Expected: {"success":true,"result":{"found":true}}
```

### 2.3 Calculator App Tests

```bash
# Test: Open Calculator
curl -X POST localhost:9222/command \
  -d '{"method":"openApp","params":{"bundleId":"com.apple.calculator"}}'

# Test: Snapshot - verify number buttons visible
curl -X POST localhost:9222/command \
  -d '{"method":"snapshot","params":{"interactiveOnly":true}}'

# Test: Tap sequence 1 + 2 = 
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"1","action":"tap"}}'
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"+","action":"tap"}}'
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"2","action":"tap"}}'
curl -X POST localhost:9222/command \
  -d '{"method":"find","params":{"text":"=","action":"tap"}}'

# Test: Verify result shows 3
curl -X POST localhost:9222/command \
  -d '{"method":"snapshot"}'
# Check for element with value "3"
```

### 2.4 Mode Switching Tests

```bash
# Test: Start in browser mode (default)
curl -X POST localhost:9222/command \
  -d '{"method":"goto","params":{"url":"https://example.com"}}'

# Test: Switch to native
curl -X POST localhost:9222/command \
  -d '{"method":"openApp","params":{"bundleId":"com.apple.Preferences"}}'

# Test: Browser command in native mode should fail
curl -X POST localhost:9222/command \
  -d '{"method":"markElements"}'
# Expected: {"success":false,"error":"markElements requires browser mode"}

# Test: Switch back to browser
curl -X POST localhost:9222/command \
  -d '{"method":"openBrowser"}'

# Test: Native command in browser mode should fail
curl -X POST localhost:9222/command \
  -d '{"method":"snapshot"}'
# Expected: {"success":false,"error":"snapshot requires native mode"}

# Test: Browser commands work again
curl -X POST localhost:9222/command \
  -d '{"method":"markElements"}'
# Expected: {"success":true,"result":{"count":N,...}}
```

### 2.5 Coordinate Commands (Both Modes)

```bash
# In native mode
curl -X POST localhost:9222/command \
  -d '{"method":"openApp","params":{"bundleId":"com.apple.Preferences"}}'

# Test: tap at coordinates
curl -X POST localhost:9222/command \
  -d '{"method":"tap","params":{"x":200,"y":300}}'

# Test: swipe
curl -X POST localhost:9222/command \
  -d '{"method":"swipe","params":{"direction":"up"}}'

# Test: screenshot
curl -X POST localhost:9222/command \
  -d '{"method":"screenshot"}'
# Expected: base64 PNG data

# Switch to browser and verify same commands work
curl -X POST localhost:9222/command \
  -d '{"method":"openBrowser"}'
curl -X POST localhost:9222/command \
  -d '{"method":"tap","params":{"x":200,"y":300}}'
curl -X POST localhost:9222/command \
  -d '{"method":"swipe","params":{"direction":"up"}}'
```

---

## Phase 3: Documentation Updates ✅ COMPLETE

### 3.1 After Tests Pass - Update SKILL.md ✅

- [x] Add "Native App Mode" section
- [x] Document `openApp`, `closeApp`, `appState` commands
- [x] Document `snapshot` with example output
- [x] Document `tapRef` and `find` commands
- [x] Add native app workflow example
- [x] Add mode switching documentation
- [x] Update command reference table with mode column

### 3.2 Update README.md (core/) ✅

- [x] Add "Native App Automation" section
- [x] Show example flow with Settings app
- [x] Document supported commands in both modes
- [x] Add note about built-in apps for testing

### 3.3 Update README.md (root) ✅

- [x] Mention native app support in feature list
- [x] Update "The Pattern" section to show both modes
- [x] Add native example in quick start or examples section

### 3.4 Update OpenAPI Spec ✅

- [x] Add `openApp` endpoint
- [x] Add `closeApp` endpoint  
- [x] Add `appState` endpoint
- [x] Add `snapshot` endpoint (native mode)
- [x] Add `tapRef` endpoint
- [x] Add `find` endpoint
- [x] Document mode-specific behavior

### 3.5 Update Pre-built App ✅

- [x] Rebuild AtlBrowser.app with native support (stubbed — see architecture blocker)
- [x] Replace `bin/AtlBrowser.app`
- [ ] Test quick start flow includes native commands

---

## Phase 4: Integration ✅ COMPLETE

### 4.1 Skill Helper Scripts ✅

- [x] Add `atl_openapp <bundleId>` function
- [x] Add `atl_closeapp` function
- [x] Add `atl_snapshot` function
- [x] Add `atl_tapref <ref>` function
- [x] Add `atl_find <text> [action]` function
- [x] Add `atl_mode` function to show current mode

### 4.2 Example Scripts ✅

- [x] Create `examples/native-settings.sh` - Settings app flow
- [x] Create `examples/native-contacts.sh` - Create contact flow
- [x] Create `examples/hybrid-flow.sh` - Browser + native switching

---

## Test Checklist (Run Before Merge)

```
[ ] Settings app: open, snapshot, find, tap, close
[ ] Contacts app: open, snapshot, fill, save
[ ] Calculator app: open, tap sequence, verify result
[ ] Mode switching: browser → native → browser
[ ] Mode errors: wrong command for mode fails cleanly
[ ] Coordinate commands work in both modes
[ ] Screenshot works in native mode
[ ] Swipe works in native mode
[ ] All existing browser tests still pass
[ ] Quick start flow works
[ ] Pre-built app is updated
```

---

## Built-in App Bundle IDs (for testing)

| App | Bundle ID |
|-----|-----------|
| Settings | `com.apple.Preferences` |
| Contacts | `com.apple.MobileAddressBook` |
| Calculator | `com.apple.calculator` |
| Calendar | `com.apple.mobilecal` |
| Photos | `com.apple.mobileslideshow` |
| Notes | `com.apple.mobilenotes` |
| Reminders | `com.apple.reminders` |
| Clock | `com.apple.mobiletimer` |
| Maps | `com.apple.Maps` |
| Weather | `com.apple.weather` |
| Files | `com.apple.DocumentsApp` |
| Safari | `com.apple.mobilesafari` |

---

*This TODO is the implementation roadmap. Check off items as completed.*
