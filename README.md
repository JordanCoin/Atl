# ATL — Agent Touch Layer

> The automation layer between AI agents and iOS

Mobile browser automation via iOS Simulator. Built for AI agents — vision-free automation with numbered marks.

![ATL marks on Target.com](core/docs/marks-example.png)
*Numbered marks on interactive elements — no vision model needed*

## The Pattern

```
markElements → getMarkInfo → tap x,y
```

No CSS selectors. No vision API calls. The browser labels everything with numbers + coordinates.

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
