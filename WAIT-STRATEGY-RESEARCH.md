# ATL Wait Strategy Research

**Date:** 2026-03-04 (Night Shift)
**Triggered by:** Doe's request for better site loading wait behavior

---

## The Problem

WKWebView's native callbacks (`didFinishNavigation`, `estimatedProgress`) fire BEFORE:
- JavaScript frameworks finish rendering (React, Vue, etc.)
- Lazy-loaded content appears
- Dynamic elements from API calls populate
- Modals/overlays finish animating

This causes ATL to interact with pages before they're truly ready.

---

## Key Research Findings

### 1. Native WKWebView Limitations (Confirmed)

**From Stack Overflow investigation:**
- `didFinishNavigation` fires when initial HTML + CSS load completes, NOT when JS finishes
- `estimatedProgress` via KVO reaches 1.0 at the same time — equally unreliable
- This is documented Apple behavior, not a bug

**Quote:** "I have an app that has been doing this for years, and the only reliable way to wait for the DOM to be populated was using JavaScript."

### 2. Playwright's Approach (Gold Standard)

Playwright defines three load states:
- **`domcontentloaded`** — HTML parsed, DOM ready (but not resources)
- **`load`** — All resources (images, scripts) loaded
- **`networkidle`** — No network requests for 500ms (discouraged by Playwright themselves!)

**Critical insight:** Playwright recommends waiting for *specific elements* rather than generic load states:
```javascript
await page.waitForSelector('.product-list');  // Better
await page.waitForLoadState('networkidle');   // Worse
```

### 3. Why `networkidle` Is Problematic

From BrowserStack (Jan 2026):
> "Discouraged — wait until there are no network connections for at least 500ms"

Issues:
- Fails on pages with analytics/polling (constant network activity)
- Too slow on fast-loading pages
- False positives when page loads in bursts

### 4. The SPA Challenge

Single-page apps (Target, Amazon, modern e-commerce):
- Initial HTML is minimal shell
- React/Vue/etc. hydrate and render content asynchronously
- Content loads via XHR/fetch after initial page load
- `didFinishNavigation` fires long before content appears

---

## Recommended ATL Strategy

### Tier 1: Element-Based Waiting (Most Reliable)

```javascript
// Wait for specific element to appear
async function waitForElement(selector, timeout = 10000) {
    const startTime = Date.now();
    while (Date.now() - startTime < timeout) {
        const element = document.querySelector(selector);
        if (element && element.offsetParent !== null) { // visible
            return element;
        }
        await new Promise(r => setTimeout(r, 100));
    }
    throw new Error(`Element ${selector} not found after ${timeout}ms`);
}
```

**CLI example:**
```bash
atl wait --for-text "Add to cart"    # Already implemented ✅
atl wait --for-selector ".product-card"  # NEW: Add this
```

### Tier 2: DOM Stability (For Generic Pages)

Already in ATL via `waitForDOMStable`:
- MutationObserver tracks DOM changes
- Wait until no mutations for N ms
- Works well for most pages

**Enhancement needed:** Lower the threshold for "stability" from 1500ms to 500ms (Playwright default), but make it configurable.

### Tier 3: Network Quiet (Last Resort)

Already in ATL via `waitForNetworkIdle`:
- Track in-flight fetch/XHR requests
- Wait until none for N ms

**Enhancement needed:** Track WebSocket activity too (some SPAs use WebSockets).

---

## Objective-C / Lower-Level APIs Investigation

Doe asked if Objective-C or lower-level APIs could help. Research findings:

### Not Useful for This Problem:
- **WKNavigationDelegate** — All callbacks fire too early (before JS execution)
- **KVO on `estimatedProgress`** — Same timing as `didFinishNavigation`
- **WKURLSchemeHandler** — For custom URL schemes, not load detection

### Potentially Useful:
- **WKWebView.evaluateJavaScript() with polling** — Current approach, works
- **WKUserScript at `atDocumentStart`** — Already using this ✅
- **WKScriptMessageHandler** — Already planned (push events from JS → Swift)

### Conclusion:
JavaScript-based detection is the correct approach. No Objective-C shortcut exists for "wait until React finishes rendering." The native APIs simply don't have visibility into JS framework lifecycle.

---

## Immediate Actions (Prioritized)

### 1. Add `--for-selector` to `atl wait` (30 min)
```bash
atl wait --for-selector ".product-grid"
```
Most reliable for automation scripts.

### 2. Lower default DOM stability threshold (5 min)
Change from 1500ms → 500ms, add `--stability-ms` flag for override.

### 3. Add `waitForElement` server method (20 min)
```json
{"method": "waitForElement", "params": {"selector": ".product-grid", "timeout": 10000}}
```

### 4. WebSocket tracking in network idle detection (45 min)
Track WebSocket connections, not just fetch/XHR.

---

## Not Recommended

- **Pure native solution** — Doesn't exist for JS framework detection
- **Hardcoded delays** (`sleep(3)`) — Unreliable and slow
- **networkidle as default** — Too many false positives/negatives

---

## References

- [WKWebView didFinish too early](https://stackoverflow.com/questions/30291534/wkwebview-didnt-finish-loading-when-didfinishnavigation-is-called-bug-in-wkw)
- [Playwright waitForLoadState](https://playwright.dev/docs/api/class-page#page-wait-for-load-state)
- [Playwright best practices](https://www.browserstack.com/guide/playwright-waitforloadstate) — "Don't use networkidle unless required"
- [WKWebView KVO estimatedProgress](https://www.hackingwithswift.com/example-code/wkwebview/how-to-monitor-wkwebview-page-load-progress-using-key-value-observing)

---

*Research conducted during Night Shift 2026-03-04. Doe can decide which improvements to prioritize.*
