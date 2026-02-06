# Native App Support - Implementation TODO

## Phase 1: Core Infrastructure

### 1.1 NativeController.swift
- [ ] Create `NativeController.swift` in `AtlBrowserPackage/Sources/AtlBrowserFeature/`
- [ ] Implement `openApp(bundleId: String)` using `XCUIApplication(bundleIdentifier:)`
- [ ] Implement `closeApp(bundleId: String?)`
- [ ] Implement `appState()` → returns current bundleId and mode
- [ ] Track `currentApp: XCUIApplication?` and `currentBundleId: String?`
- [ ] Handle app activation with `app.activate()` and `waitForExistence(timeout:)`

### 1.2 Accessibility Snapshot
- [ ] Implement `snapshot(interactiveOnly: Bool, maxDepth: Int?)` 
- [ ] Walk `app.descendants(matching: .any).allElementsBoundByIndex`
- [ ] Extract for each element:
  - `ref` (e.g., "e0", "e1", "e2")
  - `type` (XCUIElement.ElementType as string)
  - `label` (element.label)
  - `value` (element.value as? String)
  - `identifier` (element.identifier)
  - `x`, `y`, `width`, `height` (from element.frame)
  - `isHittable` (element.isHittable)
  - `isEnabled` (element.isEnabled)
- [ ] Filter non-hittable elements when `interactiveOnly: true`
- [ ] Limit traversal depth when `maxDepth` specified
- [ ] Cap max elements (e.g., 500) to avoid huge responses

### 1.3 Ref-Based Interaction
- [ ] Implement `tapRef(ref: String)` - parse ref, find element, tap
- [ ] Implement `fillRef(ref: String, text: String)` - tap then type
- [ ] Implement `focusRef(ref: String)` - tap without typing
- [ ] Store element index mapping from last snapshot for ref lookup

### 1.4 Semantic Find
- [ ] Implement `find(text: String, by: FindBy, action: FindAction, value: String?)`
- [ ] FindBy enum: `.any`, `.label`, `.value`, `.identifier`, `.type`
- [ ] FindAction enum: `.tap`, `.fill`, `.exists`, `.get`
- [ ] Use NSPredicate for flexible matching
- [ ] Return `{found: Bool, ref: String?, element: ElementInfo?}`

### 1.5 CommandServer Integration
- [ ] Add `nativeController: NativeController?` property
- [ ] Add `mode: AutomationMode` enum (`.browser`, `.native`)
- [ ] Route new commands:
  - `openApp` → nativeController.openApp()
  - `closeApp` → nativeController.closeApp()
  - `appState` → return mode + bundleId
  - `snapshot` → nativeController.snapshot() (native mode only)
  - `tapRef` → nativeController.tapRef()
  - `find` → nativeController.find()
  - `openBrowser` → switch back to browser mode
- [ ] Validate mode for mode-specific commands (error if wrong mode)
- [ ] Ensure `tap`, `swipe`, `pinch`, `screenshot` work in both modes

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

## Phase 3: Documentation Updates

### 3.1 After Tests Pass - Update SKILL.md

- [ ] Add "Native App Mode" section
- [ ] Document `openApp`, `closeApp`, `appState` commands
- [ ] Document `snapshot` with example output
- [ ] Document `tapRef` and `find` commands
- [ ] Add native app workflow example
- [ ] Add mode switching documentation
- [ ] Update command reference table with mode column

### 3.2 Update README.md (core/)

- [ ] Add "Native App Automation" section
- [ ] Show example flow with Settings app
- [ ] Document supported commands in both modes
- [ ] Add note about built-in apps for testing

### 3.3 Update README.md (root)

- [ ] Mention native app support in feature list
- [ ] Update "The Pattern" section to show both modes
- [ ] Add native example in quick start or examples section

### 3.4 Update OpenAPI Spec

- [ ] Add `openApp` endpoint
- [ ] Add `closeApp` endpoint  
- [ ] Add `appState` endpoint
- [ ] Add `snapshot` endpoint (native mode)
- [ ] Add `tapRef` endpoint
- [ ] Add `find` endpoint
- [ ] Document mode-specific behavior

### 3.5 Update Pre-built App

- [ ] Rebuild AtlBrowser.app with native support
- [ ] Replace `bin/AtlBrowser.app`
- [ ] Test quick start flow includes native commands

---

## Phase 4: Integration

### 4.1 Skill Helper Scripts

- [ ] Add `atl_openapp <bundleId>` function
- [ ] Add `atl_closeapp` function
- [ ] Add `atl_snapshot` function
- [ ] Add `atl_tapref <ref>` function
- [ ] Add `atl_find <text> [action]` function
- [ ] Add `atl_mode` function to show current mode

### 4.2 Example Scripts

- [ ] Create `examples/native-settings.sh` - Settings app flow
- [ ] Create `examples/native-contacts.sh` - Create contact flow
- [ ] Create `examples/hybrid-flow.sh` - Browser + native switching

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
