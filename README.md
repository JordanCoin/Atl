# ATL

iOS Browser Automation via Simulator. Fast, simple API.

## The Pattern

Every page interaction is 3 calls:

```
goto → markAll → clickMark
```

No CSS selectors. No XPath. The browser labels everything with numbers, you click by number.

## Quick Start

```bash
cd core
./bin/atl start
# API ready at http://localhost:9222
```

## Example

```bash
# Navigate
curl -X POST localhost:9222/command -d '{"method":"goto","params":{"url":"https://amazon.com"}}'

# Mark all interactive elements (returns JSON with labels)
curl -X POST localhost:9222/command -d '{"method":"markAll"}'

# Click element #25
curl -X POST localhost:9222/command -d '{"method":"clickMark","params":{"label":25}}'
```

**~360 automations/hour** with single simulator.

## Documentation

- [Full README](core/README.md) - API reference, CLI usage, examples
- [OpenAPI Spec](core/api/openapi.yaml) - Machine-readable API definition
- [Claude Integration](core/BROWSER-AUTOMATION.md) - Teaching AI agents to use the API

## Requirements

- macOS with Xcode (for iOS Simulator)
- No build step - pre-built app included

## License

MIT - see [LICENSE](core/LICENSE)
