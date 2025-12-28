# Production-Safe Extraction Layer v2

## Problem Statement

Current extraction has blind spots:
1. **Wrong page** - Target showed Nokia case, we extracted $16.95 as "AirPods price"
2. **No confidence** - Can't tell if result came from reliable selector vs sketchy regex
3. **Naive fallback** - Regex takes FIRST price match, not necessarily THE price
4. **Silent failures** - No artifacts when extraction goes wrong

---

## Solution: Multi-Layer Extraction with Validation

```
┌─────────────────────────────────────────────────────────────┐
│                    EXTRACTION REQUEST                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              LAYER 1: PAGE VALIDATION                        │
│  • URL check (did we land on expected domain?)               │
│  • Title keywords (contains "AirPods"?)                      │
│  • Required elements exist?                                  │
│  • Bot detection / CAPTCHA check                             │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │ VALIDATION FAILED │──► Abort + Artifacts
                    └───────────────────┘
                              │ PASSED
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              LAYER 2: SELECTOR CHAIN                         │
│  Try each CSS selector in order                              │
│  Confidence: HIGH (0.9) for primary, MEDIUM (0.7) for later  │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │  SELECTOR FOUND?  │
                    └───────────────────┘
                      YES │         │ NO
                          ▼         ▼
┌───────────────────────────┐   ┌─────────────────────────────┐
│ Return HIGH confidence    │   │ LAYER 3: CANDIDATE RANKING  │
└───────────────────────────┘   │ Extract ALL regex matches   │
                                │ Score each candidate        │
                                │ Return best + LOW confidence│
                                └─────────────────────────────┘
                                              │
                                              ▼
┌─────────────────────────────────────────────────────────────┐
│              LAYER 4: VALUE VALIDATION                       │
│  • Type check (is it a number?)                              │
│  • Range check ($50-$500 for electronics?)                   │
│  • Sanity check (price changed >50%?)                        │
└─────────────────────────────────────────────────────────────┘
```

---

## Updated JSON Schema

```json
{
  "id": "extract-price",
  "action": "extract",
  "field": "price",

  "pageValidation": {
    "urlContains": ["amazon.com/dp/"],
    "urlNotContains": ["signin", "captcha"],
    "titleContains": ["AirPods"],
    "titleNotContains": ["Robot Check", "Page Not Found"],
    "requiredElements": ["#productTitle"],
    "forbiddenElements": ["#captcha"]
  },

  "selector": {
    "chain": [
      ".a-price .a-offscreen",
      "#priceblock_ourprice"
    ],
    "fallback": {
      "type": "regex",
      "pattern": "\\$([0-9]{1,4}\\.?[0-9]{0,2})",
      "ranking": {
        "preferRange": [100, 300],
        "avoidPatterns": ["shipping", "tax", "was"],
        "preferPatterns": ["add to cart", "buy now"]
      }
    }
  },

  "validation": {
    "type": "number",
    "range": [50, 500]
  }
}
```

---

## Swift Types

```swift
struct ExtractionResultV2: Codable {
    let value: AnyCodable?
    let confidence: Double          // 0.0 - 1.0
    let method: ExtractionMethod
    let selectorUsed: String?
    let candidates: [Candidate]?
    let validationErrors: [String]
    let pageValidation: PageValidationResult
    let artifacts: ArtifactPaths?
}

enum ExtractionMethod: String, Codable {
    case primarySelector      // First selector matched
    case fallbackSelector     // Later selector matched
    case regexRanked          // Regex with ranking
    case failed
}

struct Candidate: Codable {
    let value: AnyCodable
    let score: Double            // 0.0 - 1.0
    let context: String?         // surrounding text
    let reasoning: [String]      // why this score
}

enum ConfidenceLevel {
    static let primarySelector: Double = 0.95
    static let secondarySelector: Double = 0.85
    static let regexRanked: Double = 0.50
    static let regexFirst: Double = 0.35
}
```

---

## Candidate Ranking Logic

```swift
func rankCandidate(value: Double, context: String, config: RankingConfig) -> Double {
    var score = 0.5  // Base

    // In expected range?
    if value >= config.preferRange[0] && value <= config.preferRange[1] {
        score += 0.2  // Bonus
    } else {
        score -= 0.3  // Penalty
    }

    // Near bad keywords? (shipping, tax, was)
    for pattern in config.avoidPatterns {
        if context.contains(pattern) {
            score -= 0.2
            break
        }
    }

    // Near good keywords? (add to cart, price)
    for pattern in config.preferPatterns {
        if context.contains(pattern) {
            score += 0.15
            break
        }
    }

    return max(0, min(1, score))
}
```

---

## Example Outputs

### High Confidence (Primary Selector)
```json
{
  "value": 199.00,
  "confidence": 0.95,
  "method": "primarySelector",
  "selectorUsed": ".a-price .a-offscreen",
  "validationErrors": [],
  "pageValidation": {"passed": true}
}
```

### Low Confidence (Regex Ranked)
```json
{
  "value": 197.00,
  "confidence": 0.42,
  "method": "regexRanked",
  "candidates": [
    {"value": 197, "score": 0.85, "context": "...price: $197 add to cart..."},
    {"value": 249, "score": 0.35, "context": "...was $249 save..."},
    {"value": 12.99, "score": 0.2, "context": "...shipping $12.99..."}
  ]
}
```

### Failed (Wrong Page)
```json
{
  "value": null,
  "confidence": 0,
  "method": "failed",
  "validationErrors": ["Page title missing expected keywords"],
  "pageValidation": {
    "passed": false,
    "failedChecks": ["titleContains: expected 'AirPods', got 'Nokia Phone Case'"]
  },
  "artifacts": {
    "screenshot": "artifacts/failed.png",
    "html": "artifacts/failed.html"
  }
}
```

---

## Confidence Thresholds

| Confidence | Action |
|------------|--------|
| ≥ 0.85 | ✅ Trust completely |
| 0.60-0.84 | ⚠️ Use with caution |
| 0.40-0.59 | 🟡 Needs human review |
| < 0.40 | ❌ Don't use |
