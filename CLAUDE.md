# ATL — Agent Touch Layer

## What This Is

iOS browser and native app automation via HTTP. An agent-friendly alternative to Playwright/Selenium that runs in iOS Simulator. Two modes:

- **Browser mode** (port 9222): Mobile Safari automation via `goto → markAll → clickMark`
- **Native mode** (port 9223): iOS app automation via `openApp → snapshot → tapRef/find`

## Project Layout

```
Atl/
├── core/
│   ├── AtlBrowser/                # Xcode workspace — the iOS app + HTTP server
│   │   ├── AtlBrowser.xcworkspace # USE THIS for builds (not .xcodeproj)
│   │   ├── AtlBrowserPackage/     # All source code lives here (SPM package)
│   │   │   └── Sources/AtlBrowserFeature/
│   │   │       ├── BrowserController.swift   # Core browser automation logic
│   │   │       └── CommandServer.swift       # HTTP server (FlyingFox, port 9222)
│   │   └── AtlBrowserUITests/     # Native server runs as UI test (port 9223)
│   ├── cli/                       # Swift CLI (ArgumentParser-based)
│   │   ├── Sources/ATL.swift      # Single-file CLI — all commands here
│   │   └── Package.swift          # swift-tools-version:5.9
│   ├── bin/                       # Pre-built binaries
│   │   ├── AtlBrowser.app/        # Pre-built app (skip building from source)
│   │   ├── atl-sim                # Simulator lifecycle script (start/stop/status)
│   │   └── cart                   # Cart automation demo script
│   ├── api/openapi.yaml           # OpenAPI spec for all commands
│   ├── skill/SKILL.md             # Full agent skill documentation
│   └── docs/                      # Research docs and RFCs
├── WAIT-STRATEGY-RESEARCH.md      # Wait strategy investigation
└── ATL-IMPROVEMENTS.md            # Planned improvements
```

**Important:** `bin/atl-sim` is the simulator lifecycle script (start/stop/status). The Swift CLI is at `core/cli/` — install with `cd core/cli && make install`.

## From-Scratch Setup

### 1. Boot Simulator & Build (via XcodeBuildMCP)

```
# Set defaults
session_set_defaults({
  workspacePath: "/path/to/Atl/core/AtlBrowser/AtlBrowser.xcworkspace",
  scheme: "AtlBrowser",
  bundleId: "com.atl.browser",
  simulatorName: "iPhone 17 Pro",
  useLatestOS: true,
  derivedDataPath: "/tmp/atl-dd"
})

# Boot + open simulator
boot_sim()
open_sim()

# Build and run (installs + launches automatically)
build_run_sim()
```

### 2. Verify Server

```bash
curl -s http://localhost:9222/ping
# → {"status":"ok"}
```

### 3. Install the Swift CLI (optional)

```bash
cd core/cli && make install
# Installs `atl` to /usr/local/bin
```

### 4. Start Native Server (optional, for native app automation)

```bash
xcodebuild test -workspace core/AtlBrowser/AtlBrowser.xcworkspace \
  -scheme AtlBrowser \
  -destination 'id=<SIMULATOR_UDID>' \
  -only-testing:AtlBrowserUITests/NativeServer/testNativeServer &
```

## CLI Usage

The Swift CLI (install via `cd core/cli && make install`) is the primary agent interface:

```bash
atl ping                              # Health check
atl goto https://example.com          # Navigate
atl goto https://example.com --wait   # Navigate + wait for DOM stable
atl wait 500                          # Wait for DOM stability (ms)
atl wait --for-text "Add to cart"     # Wait for text to appear
atl wait --for-selector ".product"    # Wait for CSS selector
atl wait --network 500               # Wait for network idle
atl snapshot                          # Get marks + text (truncated)
atl snapshot --full                   # Get all marks (not truncated)
atl snapshot --json                   # JSON output for agent consumption
atl snapshot --pdf -o page.pdf        # Marks + text + PDF export
atl mark                              # Mark interactive elements (full details)
atl mark --compact                    # Compact marks (label:text pairs)
atl click "Add to cart"               # Click by text content
atl click --label 25                  # Click by mark label number
atl click "Add to cart" --exact       # Exact text match
atl type "search query"               # Type into focused element
atl type "search query" --enter       # Type + press Enter
atl screenshot -o shot.png            # Screenshot (unmarks first)
atl pdf -o page.pdf                   # Full page PDF (unmarks first)
atl back                              # Browser back
atl reload                            # Reload page
atl reset                             # Reset to about:blank
atl reset --clear-cookies             # Reset + clear cookies
atl state                             # Get ATL tracking state
atl debug <method> --params '{...}'   # Raw API call with verbose logging
```

### Recommended Agent Workflow

```bash
atl goto "https://target.com" --wait
atl snapshot --json                    # Get marks + text as JSON
atl click "Sign in"                    # Click by text
atl wait --for-text "Email"            # Wait for next page
atl type "user@example.com" --enter    # Fill + submit
```

### JSON Mode (for structured agent output)

Use `--json` flag on commands that support it (goto, snapshot) for machine-parseable output:
```bash
atl snapshot --json | jq '.marks'
```

## HTTP API (curl fallback)

When the CLI has issues, use curl directly. All commands go to `POST http://localhost:9222/command`:

```bash
# Navigate
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"1","method":"goto","params":{"url":"https://example.com"}}'

# Agent snapshot (marks + text + optional PDF — best single command)
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"2","method":"agentSnapshot","params":{"pdf":false}}'

# Click by text (no need to parse marks)
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"3","method":"clickText","params":{"text":"Add to cart"}}'

# Mark all interactive elements
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"4","method":"markAll"}'

# Click by label number
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"5","method":"clickMark","params":{"label":25}}'

# Take screenshot
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"6","method":"screenshot"}' | jq -r '.result.data' | base64 -d > shot.png

# Wait for DOM stability
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"7","method":"waitForDOMStable","params":{"stabilityMs":500,"timeout":10}}'

# Wait for element
curl -s -X POST localhost:9222/command \
  -H "Content-Type: application/json" \
  -d '{"id":"8","method":"waitForSelector","params":{"selector":".product-grid","timeout":10}}'
```

## Key Server Commands Reference

| Command | Params | Description |
|---------|--------|-------------|
| `agentSnapshot` | `{pdf?}` | **Best for agents** — marks + text + URL + title + optional PDF in one call |
| `clickText` | `{text, exact?}` | Click element by visible text (no marks needed) |
| `goto` | `{url}` | Navigate to URL |
| `markAll` | — | Mark ALL interactive elements with label numbers |
| `markCompact` | — | Compact marks output (label:text pairs) |
| `clickMark` | `{label}` | Click by mark label number |
| `getMarkInfo` | `{label}` | Get element coordinates/info by label |
| `tap` | `{x, y}` | Tap at screen coordinates |
| `swipe` | `{direction}` or `{fromX,fromY,toX,toY}` | Swipe gesture |
| `type` | `{text}` | Type into focused element |
| `fill` | `{selector, value}` | Fill input by CSS selector |
| `press` | `{key}` | Press key (Enter, Tab, etc.) |
| `screenshot` | `{fullPage?}` | PNG (viewport) or PDF (fullPage:true) |
| `waitForDOMStable` | `{stabilityMs?, timeout?}` | Wait for no DOM mutations |
| `waitForSelector` | `{selector, timeout?}` | Wait for CSS selector to appear |
| `waitForReady` | `{timeout?}` | Combined DOM + network ready check |
| `evaluate` | `{script}` | Execute JavaScript, return result |

### Native App Commands (port 9223)

| Command | Params | Description |
|---------|--------|-------------|
| `openApp` | `{bundleId}` | Open native app |
| `snapshot` | `{interactiveOnly?}` | Get accessibility tree with refs |
| `tapRef` | `{ref}` | Tap element by ref (e.g., "e5") |
| `find` | `{text, action, value?}` | Find and interact by text |
| `closeApp` | — | Close current app |

Common bundle IDs: Settings=`com.apple.Preferences`, Contacts=`com.apple.MobileAddressBook`, Calculator=`com.apple.calculator`, Safari=`com.apple.mobilesafari`

## The Automation Pattern

```
Level 1: COORDINATES (fast, no vision API needed)
  markAll/agentSnapshot → clickText or clickMark → verify with snapshot

Level 2: VISION FALLBACK (when stuck)
  screenshot → analyze with vision model → identify blockers (modals, etc.)

Level 3: JS INJECTION (last resort, browser only)
  evaluate → direct DOM manipulation
```

**Always dismiss popups first** — cookie banners, newsletter modals, "download our app" prompts. Look for: close, dismiss, no thanks, accept, got it, continue.

**Always verify after actions** — take a snapshot after clicking to confirm state changed. Modals frequently appear (size selector, upsell, confirmation).

## Known Issues & Gotchas

### `bin/atl-sim` vs `atl` CLI
These are DIFFERENT tools. `bin/atl-sim` is a shell script for simulator lifecycle (`start`, `stop`, `status`). The Swift CLI (`atl`, installed via `make install`) handles automation commands (`goto`, `snapshot`, `click`, etc.).

### Wait strategy param differences
- Server `waitForDOMStable` expects `timeout` in **seconds**
- Server `waitForSelector` expects `timeout` in **seconds**
- CLI `--timeout` flag is in **milliseconds** and converts internally

### Native server setup is complex
Native app automation (port 9223) requires running `xcodebuild test` to start the UI test runner. Browser mode (port 9222) just needs the app running.

### `goto` can silently fail
Known issue where `goto` returns success but doesn't navigate. Workaround: use `evaluate` with `location.href = "..."` and then `waitForReady`.

## Development Notes

- **All source code is in the SPM package** (`AtlBrowserPackage/Sources/AtlBrowserFeature/`), not in the Xcode project
- **Swift 6.1+**, iOS 18.0+ deployment target, strict concurrency
- **Architecture:** MV pattern (no ViewModels), `@MainActor` isolation
- **Server:** `CommandServer.swift` uses FlyingFox HTTP server, delegates to `BrowserController.swift`
- **Tests:** Swift Testing framework (`@Test`, `#expect`)
- **Build with XcodeBuildMCP** preferred over raw xcodebuild commands
