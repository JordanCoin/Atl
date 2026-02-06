# ATL — Agent Touch Layer

> The automation layer between AI agents and iOS

Mobile browser automation via iOS Simulator. Built for AI agents — start with coordinates, escalate to vision only when needed.

![ATL marks on Target.com](core/docs/marks-example.png)
*Numbered marks give you coordinates — vision API only when stuck*

## The Pattern

```
markElements → getMarkInfo → tap x,y → screenshot if stuck
```

**Tiered automation:**
1. **Coordinates first** — marks give you x,y without vision calls (90% of actions)
2. **Vision fallback** — screenshot when stuck to see modals/blockers
3. **JS injection** — direct DOM manipulation as last resort

## Quick Start

```bash
git clone https://github.com/JordanCoin/Atl.git
cd Atl/core
./bin/atl start
# API ready at http://localhost:9222
```

## Example

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
