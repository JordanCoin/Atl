# ATL — Agent Touch Layer

> The automation layer between AI agents and iOS

Mobile browser and native app automation via iOS Simulator. Built for AI agents — start with coordinates, escalate to vision only when needed.

![ATL marks on Target.com](core/docs/marks-example.png)
*Numbered marks give you coordinates — vision API only when stuck*

## The Pattern

### Browser Mode (default)
```
markElements → getMarkInfo → tap x,y → screenshot if stuck
```

### Native App Mode
```
openApp → snapshot → find/tapRef → screenshot if stuck
```

**Tiered automation:**
1. **Coordinates first** — marks (browser) or refs (native) give you x,y without vision calls (90% of actions)
2. **Vision fallback** — screenshot when stuck to see modals/blockers
3. **JS injection** — direct DOM manipulation as last resort (browser only)

## Quick Start

```bash
git clone https://github.com/JordanCoin/Atl.git
cd Atl/core
./bin/atl-sim start
# API ready at http://localhost:9222
```

## CLI

Swift CLI for agent-friendly automation:

```bash
cd core/cli && swift build -c release
.build/release/atl ping                    # Check server
.build/release/atl goto https://target.com # Navigate
.build/release/atl wait --for-selector ".product-grid"  # Wait for element (SPA-safe)
.build/release/atl snapshot                # Get marks + text
.build/release/atl click "Add to cart"     # Click by text
.build/release/atl pdf -o cart.pdf         # Capture PDF
```

**Wait strategies** (for SPAs like Target, Amazon):
- `--for-selector` — Wait for CSS selector (most reliable)
- `--for-text` — Wait for text to appear
- `--network 500` — Wait for network idle (500ms quiet)
- Default: DOM stability (500ms no mutations)

## Example

### Browser Automation
```bash
# Navigate
curl -X POST localhost:9222/command -d '{"method":"goto","params":{"url":"https://target.com"}}'

# Mark all interactive elements
curl -X POST localhost:9222/command -d '{"method":"markAll"}'

# Get coordinates for element #26
curl -X POST localhost:9222/command -d '{"method":"getMarkInfo","params":{"label":26}}'
# → {"x":43, "y":539, "text":"Add to cart"}

# Tap at exact coordinates
curl -X POST localhost:9222/command -d '{"method":"tap","params":{"x":214,"y":561}}'
```

### Native App Automation
```bash
# Open Settings app
curl -X POST localhost:9222/command -d '{"method":"openApp","params":{"bundleId":"com.apple.Preferences"}}'

# Snapshot accessibility tree (get refs for all elements)
curl -X POST localhost:9222/command -d '{"method":"snapshot","params":{"interactiveOnly":true}}'

# Find and tap Wi-Fi
curl -X POST localhost:9222/command -d '{"method":"find","params":{"text":"Wi-Fi","action":"tap"}}'

# Switch back to browser
curl -X POST localhost:9222/command -d '{"method":"openBrowser"}'
```

## 🤖 AI Agent Integration

### OpenClaw Skill (Recommended)

```bash
openclaw skills install ./core/skill
```

**[Full skill documentation →](core/skill/SKILL.md)** includes:
- Vision-free automation workflow
- Escalation ladder (coordinates → vision → JS)
- Touch gestures (tap, swipe, pinch)
- Helper bash functions
- Best practices & troubleshooting

### Manual Usage

See [BROWSER-AUTOMATION.md](core/BROWSER-AUTOMATION.md) for quick-start guide.

## Documentation

- [Full README](core/README.md) - Complete API reference
- [OpenClaw Skill](core/skill/) - AI agent integration
- [OpenAPI Spec](core/api/openapi.yaml) - Machine-readable API

## Requirements

- macOS with Xcode (for iOS Simulator)
- That's it!

## License

MIT - see [LICENSE](core/LICENSE)
