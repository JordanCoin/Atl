# ATL Improvements Research

**Date:** 2026-03-04  
**Goal:** Make ATL "crazy good" — handle dynamic content, lazy loading, and subtle UI changes

---

## Current State

ATL already has solid foundations in `BrowserController.swift`:
- ✅ `markInteractiveElements()` — marks visible viewport elements
- ✅ `markAllInteractiveElements()` — marks ALL elements (absolute positioning)
- ✅ `waitForReady()` — MutationObserver + network idle detection
- ✅ `SelectorCache` — learns successful selectors per domain
- ✅ `resolveSelectorV2()` — multi-layer extraction with validation
- ✅ `captureLight()` — text + interactives without screenshots

## Identified Gaps

### 1. Lazy-Loaded Elements (Issue #4)
**Problem:** Elements below the fold don't exist in DOM until scrolled into view.

**Current behavior:** `markAllInteractiveElements` only finds elements that exist in DOM at call time.

**Solution — Progressive Discovery:**
```javascript
// Scroll through entire page, collecting elements as they appear
async function discoverAllElements() {
    const elements = new Map();
    const viewportHeight = window.innerHeight;
    const totalHeight = document.body.scrollHeight;
    
    for (let y = 0; y < totalHeight; y += viewportHeight * 0.8) {
        window.scrollTo(0, y);
        await new Promise(r => setTimeout(r, 300)); // Wait for lazy load
        
        // Collect newly appeared elements
        document.querySelectorAll('a,button,input,select,[role=button]').forEach(el => {
            if (!elements.has(el)) {
                elements.set(el, {
                    docY: window.scrollY + el.getBoundingClientRect().top,
                    el: el
                });
            }
        });
    }
    
    // Scroll back to top
    window.scrollTo(0, 0);
    return Array.from(elements.values());
}
```

**Swift Integration:** Add `discoverAndMarkAll()` method that:
1. Injects discovery script
2. Waits for completion
3. Returns discovered elements with stable IDs

### 2. MutationObserver for Real-Time Changes
**Problem:** Page state changes (modals, toasts, dynamic content) aren't detected.

**Solution — Inject persistent observer:**
```javascript
(function() {
    if (window.__atlMutationState) return;
    
    window.__atlMutationState = {
        changes: [],
        newElements: [],
        removedElements: []
    };
    
    const observer = new MutationObserver(mutations => {
        mutations.forEach(m => {
            // Track added nodes
            m.addedNodes.forEach(n => {
                if (n.nodeType === 1) { // Element
                    window.__atlMutationState.newElements.push({
                        tag: n.tagName,
                        id: n.id,
                        class: n.className,
                        text: n.textContent?.slice(0, 100),
                        time: Date.now()
                    });
                }
            });
            
            // Track removed nodes
            m.removedNodes.forEach(n => {
                if (n.nodeType === 1) {
                    window.__atlMutationState.removedElements.push({
                        tag: n.tagName,
                        id: n.id,
                        time: Date.now()
                    });
                }
            });
        });
    });
    
    observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['class', 'style', 'hidden', 'aria-hidden']
    });
})();
```

**New Commands:**
- `getDOMChanges` — Return accumulated changes since last call
- `waitForDOMChange` — Block until a mutation occurs matching criteria
- `clearDOMChanges` — Reset the change buffer

### 3. WKUserScript for Early Injection
**Problem:** Scripts injected via `evaluateJavaScript` miss events that happen before injection.

**Solution — Use WKUserScript at document start:**
```swift
// In setupWebView()
let atlBootstrap = WKUserScript(
    source: """
    window.__atl = {
        ready: false,
        mutations: [],
        networkRequests: [],
        errors: [],
        
        init() {
            // MutationObserver setup
            // Fetch/XHR interception
            // Error capture
            // Console capture
            this.ready = true;
        }
    };
    window.__atl.init();
    """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: false
)
config.userContentController.addUserScript(atlBootstrap)
```

### 4. WKScriptMessageHandler for Push Events
**Problem:** Currently polling for state. Push is more efficient.

**Solution — Native message handler:**
```swift
class ATLMessageHandler: NSObject, WKScriptMessageHandler {
    weak var controller: BrowserController?
    
    func userContentController(_ userContentController: WKUserContentController, 
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }
        
        switch event {
        case "domChanged":
            // Handle DOM mutation
        case "networkComplete":
            // Handle network request completion
        case "elementVisible":
            // Handle element entering viewport
        default:
            break
        }
    }
}

// JS side:
window.webkit.messageHandlers.atl.postMessage({
    event: 'domChanged',
    added: [...],
    removed: [...]
});
```

### 5. IntersectionObserver for Viewport Detection
**Problem:** Don't know which elements are actually visible.

**Solution:**
```javascript
function observeVisibility(selectors) {
    const visible = new Set();
    
    const observer = new IntersectionObserver(entries => {
        entries.forEach(e => {
            if (e.isIntersecting) {
                visible.add(e.target);
                window.webkit.messageHandlers.atl.postMessage({
                    event: 'elementVisible',
                    selector: generateSelector(e.target)
                });
            } else {
                visible.delete(e.target);
            }
        });
    }, { threshold: 0.5 });
    
    document.querySelectorAll(selectors.join(',')).forEach(el => {
        observer.observe(el);
    });
    
    return observer;
}
```

### 6. Form State Tracking
**Problem:** Form values aren't captured in marks.

**Solution — Enhance mark data:**
```javascript
// In markAllInteractiveElements:
if (el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA') {
    markedElement.value = el.value;
    markedElement.checked = el.checked; // for checkboxes/radios
    markedElement.selectedIndex = el.selectedIndex; // for selects
    markedElement.placeholder = el.placeholder;
}
```

### 7. Shadow DOM Support
**Problem:** Elements inside shadow roots aren't found.

**Solution:**
```javascript
function querySelectorDeep(selector, root = document) {
    const results = [...root.querySelectorAll(selector)];
    
    // Search shadow roots
    root.querySelectorAll('*').forEach(el => {
        if (el.shadowRoot) {
            results.push(...querySelectorDeep(selector, el.shadowRoot));
        }
    });
    
    return results;
}
```

---

## New Commands to Add

| Command | Description | Priority |
|---------|-------------|----------|
| `discoverAll` | Scroll + collect all lazy-loaded elements | HIGH |
| `getDOMChanges` | Get recent DOM mutations | HIGH |
| `waitForDOMChange` | Wait for specific mutation | MEDIUM |
| `observeVisibility` | Track which elements are visible | MEDIUM |
| `getFormState` | Get all form values | LOW |
| `queryShadow` | Query including shadow DOM | LOW |

---

## Implementation Plan

### Phase 1: Core Improvements (This Week)
1. **Inject ATL bootstrap at document start** — WKUserScript
2. **Add MutationObserver tracking** — Push changes to native
3. **Implement `discoverAll`** — Scroll-based discovery

### Phase 2: Intelligence (Next Week)
4. **Add `waitForDOMChange`** — Smart waiting
5. **IntersectionObserver integration** — Visibility tracking
6. **Enhance form state capture**

### Phase 3: Edge Cases (Later)
7. **Shadow DOM support**
8. **iframe support**
9. **Better error recovery**

---

## References

- [WKUserScript documentation](https://developer.apple.com/documentation/webkit/wkuserscript)
- [WKScriptMessageHandler](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler)
- [MutationObserver API](https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver)
- [IntersectionObserver API](https://developer.mozilla.org/en-US/docs/Web/API/Intersection_Observer_API)
- [Playwright dynamic content handling](https://blog.apify.com/scraping-single-page-applications-with-playwright/)
