#!/usr/bin/env bash
# Quick test: browse to a site, mark elements, take screenshot
set -euo pipefail

ATL_URL="${ATL_URL:-http://localhost:9222}"
OUTDIR="${1:-.}"

echo "Checking ATL..."
if ! curl -s "$ATL_URL/ping" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  echo "ATL not running. Start with: cd /path/to/Atl/core && ./bin/atl start"
  exit 1
fi
echo "ATL OK"

echo "Navigating to example.com..."
curl -s -X POST "$ATL_URL/command" \
  -d '{"id":"1","method":"goto","params":{"url":"https://example.com"}}' | jq .

sleep 2

echo "Marking all elements..."
MARKS=$(curl -s -X POST "$ATL_URL/command" -d '{"id":"2","method":"markAll"}')
echo "$MARKS" | jq '.result.count, .result.elements[:5]'

echo "Taking screenshot..."
curl -s -X POST "$ATL_URL/command" \
  -d '{"id":"3","method":"screenshot","params":{"fullPage":true}}' \
  | jq -r '.result.data' | base64 -d > "$OUTDIR/example-test.pdf"

echo "Done! Screenshot saved to $OUTDIR/example-test.pdf"
