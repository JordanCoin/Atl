# Browser Automation for Claude

You have a browser at `http://localhost:9222`. Three commands do everything:

```
goto → markAll → clickMark
```

No selectors. No DOM inspection. The browser tells you what's clickable with numbers.

## Commands

```bash
# Navigate
curl -s -X POST http://localhost:9222/command -d '{"method":"goto","params":{"url":"https://example.com"}}'

# Mark all clickable elements (returns JSON with label numbers)
curl -s -X POST http://localhost:9222/command -d '{"method":"markAll"}'

# Click by label number
curl -s -X POST http://localhost:9222/command -d '{"method":"clickMark","params":{"label":42}}'

# Type text
curl -s -X POST http://localhost:9222/command -d '{"method":"type","params":{"text":"hello"}}'

# Press key
curl -s -X POST http://localhost:9222/command -d '{"method":"press","params":{"key":"Enter"}}'

# Screenshot (fullPage:true = PDF of entire page)
curl -s -X POST http://localhost:9222/command -d '{"method":"screenshot","params":{"fullPage":true}}'
```

## Finding Elements

`markAll` returns:
```json
{"result":{"count":153,"elements":[
  {"label":0,"text":"Home","href":"/"},
  {"label":25,"text":"Add to cart"},
  {"label":42,"text":"Search","tagName":"input"}
]}}
```

Search with jq:
```bash
# Find "Add to Cart"
curl -s ... -d '{"method":"markAll"}' | jq '[.result.elements[] | select(.text | test("add to cart";"i"))][0].label'

# Find links
jq '[.result.elements[] | select(.href != null)]'

# Find inputs
jq '[.result.elements[] | select(.tagName == "input")]'
```

## Example: Add to Cart

```bash
# 1. Search page
curl -s -X POST http://localhost:9222/command -d '{"method":"goto","params":{"url":"https://amazon.com/s?k=headphones"}}'
sleep 3

# 2. Find Add to Cart
MARKS=$(curl -s -X POST http://localhost:9222/command -d '{"method":"markAll"}')
LABEL=$(echo "$MARKS" | jq -r '[.result.elements[] | select(.text | test("add to cart";"i"))][0].label')

# 3. Click it
curl -s -X POST http://localhost:9222/command -d "{\"method\":\"clickMark\",\"params\":{\"label\":$LABEL}}"

# 4. Verify
curl -s -X POST http://localhost:9222/command -d '{"method":"screenshot","params":{"fullPage":true}}' | jq -r '.result.data' | base64 -d > cart.pdf
```

## When Element Not Found

1. **Click product first** - search pages may not have direct "Add to Cart"
2. **Screenshot** - see what's actually on page
3. **Re-mark after navigation** - always markAll on new pages

## Key Rules

1. `markAll` after every navigation
2. Search JSON before clicking
3. Screenshot on failure
4. `sleep 2-3` between actions
5. Always capture final state as proof
