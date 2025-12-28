# Mobile Safari Watchdog - Selector Resilience System

## Problem
Mobile web markup is unstable:
- Same site, different layouts (A/B tests, responsive breakpoints)
- DOM structure changes between app versions
- Elements load asynchronously with varying timing
- Mobile vs desktop markup completely different

## Solution Architecture

### 1. Selector Fallback Chains

Instead of a single selector, define ordered fallback chains:

```json
{
  "selector": {
    "primary": "#productTitle",
    "fallbacks": [
      "#title",
      "h1[data-testid='product-title']",
      "h1.product-name",
      "h1"
    ],
    "extract": "textContent"
  }
}
```

**Resolution Order:**
1. Try primary selector
2. Try each fallback in order
3. If none match, try text-based extraction
4. Capture artifacts and fail gracefully

### 2. Run Status Levels

```
SUCCESS   - All primary selectors matched
DEGRADED  - Some fallbacks used, data extracted successfully
PARTIAL   - Some extractions failed, others succeeded
FAILED    - Critical selectors missing, workflow unusable
```

### 3. Validation Predicates

Verify extracted data is valid before accepting:

```json
{
  "id": "extract-price",
  "action": "extract",
  "selector": { ... },
  "saveAs": "currentPrice",
  "validate": {
    "type": "number",
    "range": [0.01, 100000],
    "required": true
  }
}
```

### 4. Retry Strategies

```
RETRY_SCROLL    - Scroll element into view, retry
RETRY_RELOAD    - Full page reload, retry
RETRY_WAIT      - Extended wait (2x timeout), retry
RETRY_VIEWPORT  - Change viewport size, retry
```

### 5. Artifact Capture on Failure

When selectors fail, automatically capture:
- Screenshot (PNG)
- Full page PDF
- DOM snapshot (HTML)
- Console logs
- Network requests

---

## Updated Workflow JSON Format

```json
{
  "id": "amazon-price-watch",
  "name": "AirPods Pro Price Monitor",
  "version": "2.0",
  "resilience": {
    "retryCount": 2,
    "retryStrategies": ["scroll", "wait", "reload"],
    "captureOnFailure": true,
    "degradedIsSuccess": true
  },
  "steps": [
    {
      "id": "load-product",
      "action": "goto",
      "params": { "url": "https://amazon.com/dp/B0D1XD1ZV3" },
      "timeout": 15000,
      "required": true
    },
    {
      "id": "wait-ready",
      "action": "waitForAny",
      "selectors": [
        "#productTitle",
        "#title",
        "h1[itemprop='name']",
        ".product-title"
      ],
      "timeout": 10000
    },
    {
      "id": "extract-title",
      "action": "extract",
      "selector": {
        "chain": ["#productTitle", "#title", "h1", "document.title"],
        "transform": "text.split('\\n')[0].trim()"
      },
      "saveAs": "productTitle",
      "validate": {
        "type": "string",
        "minLength": 3,
        "notContains": ["error", "not found"]
      },
      "required": true
    },
    {
      "id": "extract-price",
      "action": "extract",
      "selector": {
        "chain": [
          ".a-price .a-offscreen",
          "#priceblock_ourprice",
          "#corePrice_feature_div .a-offscreen",
          "[data-a-color='price'] .a-offscreen"
        ],
        "fallbackScript": "document.body.innerText.match(/\\$([0-9]+\\.?[0-9]*)/)?.[1]",
        "transform": "parseFloat(text.replace(/[^0-9.]/g, ''))"
      },
      "saveAs": "currentPrice",
      "validate": {
        "type": "number",
        "range": [1, 10000],
        "required": true
      },
      "retry": {
        "strategies": ["scroll", "wait"],
        "maxAttempts": 3
      }
    },
    {
      "id": "extract-availability",
      "action": "extract",
      "selector": {
        "chain": [
          "#availability span",
          "#availability",
          ".availabilityMessage"
        ],
        "fallbackScript": "document.body.innerText.includes('In Stock') ? 'In Stock' : document.body.innerText.includes('Add to Cart') ? 'Available' : 'Unknown'"
      },
      "saveAs": "availability",
      "required": false
    },
    {
      "id": "capture-proof",
      "action": "screenshot",
      "params": { "fullPage": true },
      "saveAs": "proofPdf"
    }
  ]
}
```

---

## Implementation Pseudocode

### SelectorChain Resolution

```swift
struct SelectorChain {
    let chain: [String]
    let fallbackScript: String?
    let transform: String?
}

struct ExtractionResult {
    let value: Any?
    let selectorUsed: String
    let wasFallback: Bool
    let attempts: Int
}

func resolveSelector(_ chain: SelectorChain, in controller: BrowserController) async -> ExtractionResult {
    var attempts = 0

    // Try each selector in chain
    for (index, selector) in chain.chain.enumerated() {
        attempts += 1

        if let element = try? await controller.querySelector(selector) {
            let rawValue = try? await controller.evaluate("document.querySelector('\(selector)').textContent")
            let value = applyTransform(rawValue, chain.transform)

            return ExtractionResult(
                value: value,
                selectorUsed: selector,
                wasFallback: index > 0,
                attempts: attempts
            )
        }
    }

    // Try fallback script if all selectors failed
    if let script = chain.fallbackScript {
        attempts += 1
        if let value = try? await controller.evaluate(script) {
            return ExtractionResult(
                value: applyTransform(value, chain.transform),
                selectorUsed: "fallbackScript",
                wasFallback: true,
                attempts: attempts
            )
        }
    }

    return ExtractionResult(value: nil, selectorUsed: "none", wasFallback: true, attempts: attempts)
}
```

### waitForAnySelector

```swift
func waitForAnySelector(_ selectors: [String], timeout: TimeInterval) async throws -> String {
    let startTime = Date()
    let pollInterval: TimeInterval = 0.25

    while Date().timeIntervalSince(startTime) < timeout {
        for selector in selectors {
            let exists = try await evaluate("!!document.querySelector('\(selector)')")
            if exists as? Bool == true {
                return selector  // Return which selector matched
            }
        }
        try await Task.sleep(for: .milliseconds(250))
    }

    throw SelectorError.noneFound(tried: selectors, timeout: timeout)
}
```

### Retry with Strategies

```swift
enum RetryStrategy {
    case scroll
    case wait
    case reload
    case viewport(width: Int, height: Int)
}

func executeWithRetry(
    step: WorkflowStep,
    strategies: [RetryStrategy],
    maxAttempts: Int
) async throws -> StepResult {

    var lastError: Error?
    var attempt = 0

    for strategy in strategies {
        attempt += 1
        if attempt > maxAttempts { break }

        // Apply retry strategy
        switch strategy {
        case .scroll:
            try await controller.evaluate("window.scrollTo(0, document.body.scrollHeight / 2)")
            try await Task.sleep(for: .seconds(0.5))

        case .wait:
            try await Task.sleep(for: .seconds(2))

        case .reload:
            try await controller.reload()
            try await controller.waitForNavigation()

        case .viewport(let w, let h):
            // Resize simulator viewport (if supported)
            try await controller.setViewport(width: w, height: h)
        }

        // Retry the step
        do {
            return try await executeStep(step)
        } catch {
            lastError = error
            continue
        }
    }

    throw RetryExhaustedError(attempts: attempt, lastError: lastError)
}
```

### Artifact Capture on Failure

```swift
struct FailureArtifacts {
    let screenshot: Data      // PNG
    let fullPagePdf: Data     // PDF
    let domSnapshot: String   // HTML
    let consoleLogs: [String]
    let failedSelector: String
    let timestamp: Date
}

func captureFailureArtifacts(step: WorkflowStep, error: Error) async -> FailureArtifacts {
    async let screenshot = controller.takeScreenshot()
    async let pdf = controller.takeFullPageScreenshot()
    async let dom = controller.evaluate("document.documentElement.outerHTML")
    async let logs = controller.getConsoleLogs()

    return FailureArtifacts(
        screenshot: try await screenshot,
        fullPagePdf: try await pdf,
        domSnapshot: try await dom as? String ?? "",
        consoleLogs: try await logs,
        failedSelector: step.selector?.chain.first ?? "unknown",
        timestamp: Date()
    )
}
```

### Run Status Calculation

```swift
enum RunStatus {
    case success      // All primary selectors worked
    case degraded     // Fallbacks used but data extracted
    case partial      // Some required extractions failed
    case failed       // Critical failure
}

func calculateRunStatus(results: [StepResult]) -> RunStatus {
    let requiredSteps = results.filter { $0.step.required }
    let requiredFailed = requiredSteps.filter { !$0.success }

    if !requiredFailed.isEmpty {
        return .failed
    }

    let allFailed = results.filter { !$0.success }
    if !allFailed.isEmpty {
        return .partial
    }

    let usedFallbacks = results.filter { $0.usedFallback }
    if !usedFallbacks.isEmpty {
        return .degraded
    }

    return .success
}
```

---

## Enhanced Report Format

```json
{
  "runId": "amazon-price-watch-20251228-120000",
  "status": "degraded",
  "statusReason": "2 fallback selectors used",
  "duration": 12,
  "steps": {
    "total": 6,
    "success": 5,
    "degraded": 2,
    "failed": 0
  },
  "extracted": {
    "productTitle": {
      "value": "Apple AirPods Pro 2...",
      "selectorUsed": "h1",
      "wasFallback": true,
      "attempts": 3
    },
    "currentPrice": {
      "value": 199,
      "selectorUsed": "fallbackScript",
      "wasFallback": true,
      "attempts": 5
    },
    "availability": {
      "value": "In Stock",
      "selectorUsed": "#availability span",
      "wasFallback": false,
      "attempts": 1
    }
  },
  "artifacts": {
    "proof": "runs/.../proof.pdf",
    "domSnapshot": "runs/.../dom.html"
  },
  "failures": [],
  "recommendations": [
    "Primary selector '#productTitle' not found - consider updating workflow for mobile layout"
  ]
}
```

---

## Validation Predicate Types

```json
{
  "validate": {
    "type": "string|number|boolean|array",
    "required": true,
    "minLength": 3,
    "maxLength": 1000,
    "range": [0.01, 100000],
    "pattern": "^\\$?[0-9]+\\.?[0-9]*$",
    "notContains": ["error", "undefined", "null"],
    "contains": ["$"],
    "custom": "value > 0 && value < 10000"
  }
}
```

---

## CLI Output Example

```
[Watchdog] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[Watchdog] Mobile Safari Watchdog v2.0
[Watchdog] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[Watchdog] Workflow: AirPods Pro Price Monitor
[Watchdog] Run ID:   amazon-price-watch-20251228-120000
[✓] Server connected

[Watchdog] Executing 6 steps...

Step 1/6: load-product (goto)
  [✓] Done

Step 2/6: wait-ready (waitForAny)
  [⚠] Primary '#productTitle' not found
  [⚠] Trying fallback '#title'...
  [✓] Found via 'h1' (fallback #3)

Step 3/6: extract-title (extract)
  [⚠] '#productTitle' → not found
  [⚠] '#title' → not found
  [✓] 'h1' → "Apple AirPods Pro 2..."
  [✓] Validation passed (string, len=89)

Step 4/6: extract-price (extract)
  [⚠] Selector chain exhausted, using fallbackScript
  [✓] currentPrice = 199
  [✓] Validation passed (number in range [1, 10000])

Step 5/6: extract-availability (extract)
  [✓] '#availability span' → "In Stock"

Step 6/6: capture-proof (screenshot)
  [✓] Saved: proof.pdf (1.2MB)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STATUS: DEGRADED (2 fallbacks used)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Product:      Apple AirPods Pro 2 Wireless Earbuds...
Price:        $199
Availability: In Stock
Duration:     12s

[⚠] Recommendations:
    • Update workflow: '#productTitle' → 'h1' for mobile
    • Consider adding '.a-price' to price selector chain
```
