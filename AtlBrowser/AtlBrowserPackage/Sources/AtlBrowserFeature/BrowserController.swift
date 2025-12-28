import Foundation
import WebKit
import Combine

/// Central controller for the browser, managing WebView and command server
@MainActor
class BrowserController: ObservableObject {
    static let shared = BrowserController()

    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    private(set) var webView: WKWebView!
    private var commandServer: CommandServer!
    private var navigationDelegate: WebViewNavigationDelegate!
    private var pendingNavigations: [String: CheckedContinuation<Bool, Never>] = [:]

    private init() {
        setupWebView()
        setupCommandServer()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Enable developer extras for debugging
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        navigationDelegate = WebViewNavigationDelegate(controller: self)
        webView.navigationDelegate = navigationDelegate
    }

    private func setupCommandServer() {
        commandServer = CommandServer(port: 9222, controller: self)
        commandServer.start()
    }

    // MARK: - Navigation

    func goto(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw BrowserError.invalidURL
        }

        let request = URLRequest(url: url)
        webView.load(request)

        // Wait for navigation to complete
        _ = await waitForNavigation()
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func waitForNavigation() async -> Bool {
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pendingNavigations[id] = continuation
        }
    }

    func navigationDidFinish() {
        for (id, continuation) in pendingNavigations {
            continuation.resume(returning: true)
            pendingNavigations.removeValue(forKey: id)
        }
    }

    func navigationDidFail() {
        for (id, continuation) in pendingNavigations {
            continuation.resume(returning: false)
            pendingNavigations.removeValue(forKey: id)
        }
    }

    // MARK: - JavaScript Execution

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        // Wrap the result in a Sendable container
        let sendableResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendableValue, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: SendableValue(result))
                }
            }
        }
        return sendableResult.value
    }

    // MARK: - Element Interactions

    func click(_ selector: String) async throws {
        let script = """
        (function() {
            const el = document.querySelector('\(selector.escapedForJS)');
            if (!el) return { success: false, error: 'Element not found' };
            el.click();
            return { success: true };
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [String: Any],
              result["success"] as? Bool == true else {
            throw BrowserError.elementNotFound(selector)
        }
    }

    func doubleClick(_ selector: String) async throws {
        let script = """
        (function() {
            const el = document.querySelector('\(selector.escapedForJS)');
            if (!el) return { success: false, error: 'Element not found' };
            const event = new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window });
            el.dispatchEvent(event);
            return { success: true };
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [String: Any],
              result["success"] as? Bool == true else {
            throw BrowserError.elementNotFound(selector)
        }
    }

    func type(_ text: String) async throws {
        // Type into the currently focused element
        let script = """
        (function() {
            const el = document.activeElement;
            if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA' && !el.isContentEditable)) {
                return { success: false, error: 'No editable element focused' };
            }
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                el.value += '\(text.escapedForJS)';
                el.dispatchEvent(new Event('input', { bubbles: true }));
            } else {
                document.execCommand('insertText', false, '\(text.escapedForJS)');
            }
            return { success: true };
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [String: Any],
              result["success"] as? Bool == true else {
            throw BrowserError.noEditableElement
        }
    }

    func fill(_ selector: String, value: String) async throws {
        let script = """
        (function() {
            const el = document.querySelector('\(selector.escapedForJS)');
            if (!el) return { success: false, error: 'Element not found' };
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                el.value = '\(value.escapedForJS)';
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            } else if (el.isContentEditable) {
                el.textContent = '\(value.escapedForJS)';
            } else {
                return { success: false, error: 'Element is not fillable' };
            }
            return { success: true };
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [String: Any],
              result["success"] as? Bool == true else {
            throw BrowserError.elementNotFound(selector)
        }
    }

    func press(_ key: String) async throws {
        let script = """
        (function() {
            const key = '\(key.escapedForJS)';

            // Find the best target element - activeElement or last focused input
            let el = document.activeElement;

            // If activeElement is body, try to find a focused/recently used input
            if (!el || el === document.body) {
                el = document.querySelector('input:focus, textarea:focus') ||
                     document.querySelector('input[type="text"], input[type="search"], textarea') ||
                     document.body;
            }

            // Dispatch keydown event
            const downEvent = new KeyboardEvent('keydown', {
                key: key,
                code: key,
                keyCode: key === 'Enter' ? 13 : key === 'Escape' ? 27 : key === 'Tab' ? 9 : 0,
                which: key === 'Enter' ? 13 : key === 'Escape' ? 27 : key === 'Tab' ? 9 : 0,
                bubbles: true,
                cancelable: true
            });
            el.dispatchEvent(downEvent);

            // Dispatch keyup event
            const upEvent = new KeyboardEvent('keyup', {
                key: key,
                code: key,
                keyCode: key === 'Enter' ? 13 : key === 'Escape' ? 27 : key === 'Tab' ? 9 : 0,
                which: key === 'Enter' ? 13 : key === 'Escape' ? 27 : key === 'Tab' ? 9 : 0,
                bubbles: true,
                cancelable: true
            });
            el.dispatchEvent(upEvent);

            // Special handling for Enter key - submit form
            if (key === 'Enter') {
                // Look for form from current element or any input with value
                let form = el.closest('form');
                if (!form) {
                    // Try to find a form with a filled input
                    const inputs = document.querySelectorAll('input[type="text"], input[type="search"], textarea');
                    for (const input of inputs) {
                        if (input.value && input.closest('form')) {
                            form = input.closest('form');
                            break;
                        }
                    }
                }

                if (form) {
                    // Try to find and click a submit button first (more natural)
                    const submitBtn = form.querySelector('input[type="submit"], button[type="submit"], button:not([type])');
                    if (submitBtn && submitBtn.offsetParent !== null) {
                        submitBtn.click();
                    } else {
                        // Fall back to form.submit()
                        form.submit();
                    }
                }
            }

            return { success: true };
        })();
        """

        _ = try await evaluateJavaScript(script)
    }

    func hover(_ selector: String) async throws {
        let script = """
        (function() {
            const el = document.querySelector('\(selector.escapedForJS)');
            if (!el) return { success: false, error: 'Element not found' };
            const event = new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window });
            el.dispatchEvent(event);
            return { success: true };
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [String: Any],
              result["success"] as? Bool == true else {
            throw BrowserError.elementNotFound(selector)
        }
    }

    func scrollIntoView(_ selector: String) async throws {
        let script = """
        (function() {
            const el = document.querySelector('\(selector.escapedForJS)');
            if (!el) return { success: false, error: 'Element not found' };
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            return { success: true };
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [String: Any],
              result["success"] as? Bool == true else {
            throw BrowserError.elementNotFound(selector)
        }
    }

    // MARK: - Element Queries

    func querySelector(_ selector: String) async throws -> [String: Any]? {
        let script = """
        (function() {
            const el = document.querySelector('\(selector.escapedForJS)');
            if (!el) return null;
            const rect = el.getBoundingClientRect();
            return {
                tagName: el.tagName.toLowerCase(),
                id: el.id || null,
                className: el.className || null,
                textContent: el.textContent?.substring(0, 1000) || null,
                htmlContent: el.outerHTML?.substring(0, 2000) || null,
                attributes: Object.fromEntries([...el.attributes].map(a => [a.name, a.value])),
                boundingRect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
            };
        })();
        """

        return try await evaluateJavaScript(script) as? [String: Any]
    }

    func querySelectorAll(_ selector: String) async throws -> [[String: Any]] {
        let script = """
        (function() {
            const elements = document.querySelectorAll('\(selector.escapedForJS)');
            return [...elements].slice(0, 100).map(el => {
                const rect = el.getBoundingClientRect();
                return {
                    tagName: el.tagName.toLowerCase(),
                    id: el.id || null,
                    className: el.className || null,
                    textContent: el.textContent?.substring(0, 500) || null,
                    attributes: Object.fromEntries([...el.attributes].map(a => [a.name, a.value])),
                    boundingRect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
                };
            });
        })();
        """

        return try await evaluateJavaScript(script) as? [[String: Any]] ?? []
    }

    func waitForSelector(_ selector: String, timeout: TimeInterval) async throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let script = "document.querySelector('\(selector.escapedForJS)') !== null"
            if let found = try await evaluateJavaScript(script) as? Bool, found {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        throw BrowserError.timeout("Waiting for selector: \(selector)")
    }

    // MARK: - Screenshots

    func takeScreenshot() async throws -> Data {
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image = image,
                   let data = image.pngData() {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Take a full-page screenshot using PDF rendering (captures entire scrollable content)
    func takeFullPageScreenshot() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func takeScreenshot(selector: String) async throws -> Data {
        // Get element bounds
        let script = """
        (function() {
            const el = document.querySelector('\(selector.escapedForJS)');
            if (!el) return null;
            const rect = el.getBoundingClientRect();
            return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
        })();
        """

        guard let rect = try await evaluateJavaScript(script) as? [String: Double] else {
            throw BrowserError.elementNotFound(selector)
        }

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(
            x: rect["x"] ?? 0,
            y: rect["y"] ?? 0,
            width: rect["width"] ?? 100,
            height: rect["height"] ?? 100
        )

        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let image = image,
                   let data = image.pngData() {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - Vision Capture

    /// Capture full page PDF with metadata for vision-based automation
    /// Returns everything a vision model needs to understand and act on the page
    func captureForVision() async throws -> VisionCapture {
        let pdfData = try await takeFullPageScreenshot()

        return VisionCapture(
            pdf: pdfData,
            url: currentURL?.absoluteString ?? "",
            title: pageTitle,
            timestamp: Date()
        )
    }

    /// Save a vision capture to disk for training data
    func saveVisionCapture(_ capture: VisionCapture, to directory: URL, name: String) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Save PDF
        let pdfPath = directory.appendingPathComponent("\(name).pdf")
        try capture.pdf.write(to: pdfPath)

        // Save metadata JSON
        let metadata: [String: Any] = [
            "url": capture.url,
            "title": capture.title,
            "timestamp": ISO8601DateFormatter().string(from: capture.timestamp),
            "pdfFile": "\(name).pdf"
        ]
        let metadataPath = directory.appendingPathComponent("\(name).json")
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataData.write(to: metadataPath)

        return pdfPath
    }

    // MARK: - Optimized Capture Modes

    /// Light capture - text + interactives only (~9KB vs 1.1MB PDF)
    /// Use when Claude just needs to know what's on the page, not see it
    struct LightCapture {
        let url: String
        let title: String
        let text: String
        let interactives: [[String: Any?]]
        let timestamp: Date

        var asDict: [String: Any] {
            [
                "url": url,
                "title": title,
                "text": text,
                "interactives": interactives,
                "timestamp": ISO8601DateFormatter().string(from: timestamp)
            ]
        }
    }

    /// Capture in light mode - text and interactives only, no image
    /// ~99% smaller than PDF, sufficient for most navigation tasks
    func captureLight() async throws -> LightCapture {
        // Get page text
        let textScript = "document.body.innerText"
        let text = try await evaluateJavaScript(textScript) as? String ?? ""

        // Get interactive elements
        let interactivesScript = """
        (function(){
            const els = [];
            document.querySelectorAll('button,a[href],input,select,textarea,[role=button],[role=link],[role=menuitem]').forEach((e, i) => {
                if (i > 100) return;
                const rect = e.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) return;
                const t = e.textContent?.trim() || e.value || e.title || e.getAttribute('aria-label') || e.placeholder || '';
                if (t.length === 0 || t.length > 200) return;
                els.push({
                    tag: e.tagName,
                    type: e.type || null,
                    text: t.substring(0, 100),
                    href: e.href || null,
                    id: e.id || null,
                    name: e.name || null,
                    ariaLabel: e.getAttribute('aria-label') || null
                });
            });
            return els;
        })();
        """
        let interactives = try await evaluateJavaScript(interactivesScript) as? [[String: Any?]] ?? []

        return LightCapture(
            url: currentURL?.absoluteString ?? "",
            title: pageTitle,
            text: text,
            interactives: interactives,
            timestamp: Date()
        )
    }

    /// JPEG capture result
    struct JPEGCapture: Sendable {
        let jpeg: Data
        let url: String
        let title: String
        let width: Int
        let height: Int
        let quality: Int
        let fullPage: Bool
        let timestamp: Date
    }

    /// Capture as JPEG - smaller than PDF, still visual
    /// - Parameters:
    ///   - quality: JPEG quality 0-100 (default 80)
    ///   - fullPage: Capture full scrollable page or just viewport
    /// - Returns: JPEGCapture with image data and metadata
    func captureJPEG(quality: Int = 80, fullPage: Bool = false) async throws -> JPEGCapture {
        let imageData: Data
        let width: Int
        let height: Int

        if fullPage {
            // Full page - render PDF then convert to JPEG
            let pdfData = try await takeFullPageScreenshot()

            // Get page dimensions for metadata
            let dimensionScript = """
            (function(){
                return {
                    width: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth),
                    height: Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)
                };
            })();
            """
            let dims = try await evaluateJavaScript(dimensionScript) as? [String: Int] ?? [:]
            width = dims["width"] ?? 0
            height = dims["height"] ?? 0

            // Convert PDF to JPEG using Core Graphics
            guard let provider = CGDataProvider(data: pdfData as CFData),
                  let pdfDoc = CGPDFDocument(provider),
                  let page = pdfDoc.page(at: 1) else {
                throw BrowserError.screenshotFailed
            }

            let pageRect = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 2.0 // Retina
            let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

            let renderer = UIGraphicsImageRenderer(size: scaledSize)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: scaledSize))

                context.cgContext.translateBy(x: 0, y: scaledSize.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                context.cgContext.drawPDFPage(page)
            }

            guard let jpegData = image.jpegData(compressionQuality: CGFloat(quality) / 100.0) else {
                throw BrowserError.screenshotFailed
            }
            imageData = jpegData
        } else {
            // Viewport only - take snapshot and convert to JPEG
            let pngData = try await takeScreenshot()

            guard let uiImage = UIImage(data: pngData),
                  let jpegData = uiImage.jpegData(compressionQuality: CGFloat(quality) / 100.0) else {
                throw BrowserError.screenshotFailed
            }

            width = Int(uiImage.size.width)
            height = Int(uiImage.size.height)
            imageData = jpegData
        }

        return JPEGCapture(
            jpeg: imageData,
            url: currentURL?.absoluteString ?? "",
            title: pageTitle,
            width: width,
            height: height,
            quality: quality,
            fullPage: fullPage,
            timestamp: Date()
        )
    }

    // MARK: - Cookies

    func getCookies() async -> [[String: Any]] {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return cookies.map { cookie in
            var dict: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "httpOnly": cookie.isHTTPOnly,
                "secure": cookie.isSecure
            ]
            if let expires = cookie.expiresDate {
                dict["expires"] = expires.timeIntervalSince1970
            }
            if let sameSite = cookie.sameSitePolicy?.rawValue {
                dict["sameSite"] = sameSite
            }
            return dict
        }
    }

    func setCookies(_ cookies: [[String: Any]]) async {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore

        for cookieData in cookies {
            guard let name = cookieData["name"] as? String,
                  let value = cookieData["value"] as? String,
                  let domain = cookieData["domain"] as? String else {
                continue
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: cookieData["path"] as? String ?? "/"
            ]

            if let expires = cookieData["expires"] as? TimeInterval {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }

            if let secure = cookieData["secure"] as? Bool, secure {
                properties[.secure] = true
            }

            if let cookie = HTTPCookie(properties: properties) {
                await cookieStore.setCookie(cookie)
            }
        }
    }

    func deleteCookies() async {
        let dataStore = webView.configuration.websiteDataStore
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records)
    }

    // MARK: - Set-of-Mark (Visual Element Labeling)

    /// Mark all interactive elements with numbered labels for vision-based automation
    /// Returns array of marked elements with their labels, selectors, bounding boxes, and text
    func markInteractiveElements() async throws -> [[String: Any]] {
        let script = """
        (function() {
            // Remove any existing marks first
            document.querySelectorAll('[data-som-mark]').forEach(el => el.remove());
            document.querySelectorAll('[data-som-marked]').forEach(el => {
                el.removeAttribute('data-som-marked');
                el.style.outline = el.dataset.somOriginalOutline || '';
                delete el.dataset.somOriginalOutline;
            });

            // Find all interactive elements
            const interactiveSelectors = [
                'a[href]',
                'button',
                'input:not([type="hidden"])',
                'select',
                'textarea',
                '[role="button"]',
                '[role="link"]',
                '[role="checkbox"]',
                '[role="radio"]',
                '[role="tab"]',
                '[role="menuitem"]',
                '[onclick]',
                '[tabindex]:not([tabindex="-1"])'
            ];

            const elements = [];
            const seen = new Set();

            interactiveSelectors.forEach(selector => {
                document.querySelectorAll(selector).forEach(el => {
                    if (seen.has(el)) return;
                    seen.add(el);

                    // Skip hidden elements
                    const rect = el.getBoundingClientRect();
                    if (rect.width === 0 || rect.height === 0) return;

                    const style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return;

                    // Check if in viewport (with some margin)
                    const inViewport = rect.top < window.innerHeight + 100 &&
                                      rect.bottom > -100 &&
                                      rect.left < window.innerWidth + 100 &&
                                      rect.right > -100;
                    if (!inViewport) return;

                    elements.push(el);
                });
            });

            // Sort by position (top-to-bottom, left-to-right)
            elements.sort((a, b) => {
                const aRect = a.getBoundingClientRect();
                const bRect = b.getBoundingClientRect();
                if (Math.abs(aRect.top - bRect.top) < 20) {
                    return aRect.left - bRect.left;
                }
                return aRect.top - bRect.top;
            });

            // Create marks
            const markedElements = [];
            elements.forEach((el, index) => {
                const rect = el.getBoundingClientRect();

                // Create label element
                const mark = document.createElement('div');
                mark.setAttribute('data-som-mark', index.toString());
                mark.style.cssText = `
                    position: fixed;
                    left: ${rect.left - 2}px;
                    top: ${rect.top - 18}px;
                    background: #FF6B6B;
                    color: white;
                    font-size: 11px;
                    font-weight: bold;
                    font-family: -apple-system, sans-serif;
                    padding: 1px 4px;
                    border-radius: 3px;
                    z-index: 999999;
                    pointer-events: none;
                    box-shadow: 0 1px 3px rgba(0,0,0,0.3);
                `;
                mark.textContent = index.toString();
                document.body.appendChild(mark);

                // Add outline to element
                el.dataset.somOriginalOutline = el.style.outline || '';
                el.style.outline = '2px solid #FF6B6B';
                el.setAttribute('data-som-marked', index.toString());

                // Build unique selector for this element
                let selector = '';
                if (el.id) {
                    selector = '#' + el.id;
                } else {
                    const tag = el.tagName.toLowerCase();
                    const classes = Array.from(el.classList).slice(0, 2).join('.');
                    selector = classes ? `${tag}.${classes}` : tag;

                    // Add href or type for disambiguation
                    if (el.href) {
                        const href = el.getAttribute('href');
                        if (href && href.length < 50) {
                            selector += `[href="${href.replace(/"/g, '\\\\"')}"]`;
                        }
                    } else if (el.type) {
                        selector += `[type="${el.type}"]`;
                    } else if (el.name) {
                        selector += `[name="${el.name}"]`;
                    }
                }

                // Get meaningful text
                let text = el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || '';
                text = text.trim().substring(0, 100);

                markedElements.push({
                    label: index,
                    selector: selector,
                    tagName: el.tagName.toLowerCase(),
                    type: el.type || null,
                    text: text,
                    href: el.href || null,
                    boundingBox: {
                        x: Math.round(rect.x),
                        y: Math.round(rect.y),
                        width: Math.round(rect.width),
                        height: Math.round(rect.height)
                    }
                });
            });

            return markedElements;
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [[String: Any]] else {
            return []
        }
        return result
    }

    /// Remove all Set-of-Mark labels from the page
    func unmarkElements() async throws {
        let script = """
        (function() {
            // Remove mark labels
            document.querySelectorAll('[data-som-mark]').forEach(el => el.remove());

            // Remove outlines from marked elements
            document.querySelectorAll('[data-som-marked]').forEach(el => {
                el.style.outline = el.dataset.somOriginalOutline || '';
                delete el.dataset.somOriginalOutline;
                el.removeAttribute('data-som-marked');
            });

            return { success: true };
        })();
        """

        _ = try await evaluateJavaScript(script)
    }

    /// Click an element by its Set-of-Mark label number
    func clickByMark(_ label: Int) async throws {
        let script = """
        (function() {
            const el = document.querySelector('[data-som-marked="\(label)"]');
            if (!el) return { success: false, error: 'Mark not found: \(label)' };

            // Scroll into view if needed
            el.scrollIntoView({ behavior: 'instant', block: 'center' });

            // Click the element
            el.click();

            return { success: true, tagName: el.tagName, text: el.innerText?.substring(0, 50) || '' };
        })();
        """

        guard let result = try await evaluateJavaScript(script) as? [String: Any],
              result["success"] as? Bool == true else {
            throw BrowserError.elementNotFound("mark:\(label)")
        }
    }

    /// Get element info by Set-of-Mark label without clicking
    func getMarkInfo(_ label: Int) async throws -> [String: Any]? {
        let script = """
        (function() {
            const el = document.querySelector('[data-som-marked="\(label)"]');
            if (!el) return null;

            const rect = el.getBoundingClientRect();
            return {
                label: \(label),
                tagName: el.tagName.toLowerCase(),
                text: (el.innerText || el.value || '').trim().substring(0, 100),
                href: el.href || null,
                boundingBox: {
                    x: Math.round(rect.x),
                    y: Math.round(rect.y),
                    width: Math.round(rect.width),
                    height: Math.round(rect.height)
                }
            };
        })();
        """

        return try await evaluateJavaScript(script) as? [String: Any]
    }

    // MARK: - Selector Resilience

    /// Wait for any of the provided selectors to appear
    /// Returns the selector that matched
    func waitForAnySelector(_ selectors: [String], timeout: TimeInterval = 10) async throws -> String {
        let startTime = Date()
        let escapedSelectors = selectors.map { $0.escapedForJS }
        let selectorList = escapedSelectors.map { "'\($0)'" }.joined(separator: ", ")

        while Date().timeIntervalSince(startTime) < timeout {
            let script = """
            (function() {
                const selectors = [\(selectorList)];
                for (const sel of selectors) {
                    if (document.querySelector(sel)) return sel;
                }
                return null;
            })();
            """

            if let found = try await evaluateJavaScript(script) as? String {
                return found
            }
            try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        throw BrowserError.selectorChainExhausted(selectors)
    }

    // MARK: - Page Ready Detection

    /// Result of waitForReady check
    struct PageReadyResult: Sendable {
        let ready: Bool
        let readyState: String
        let domStable: Bool
        let networkIdle: Bool
        let waitedMs: Int
        let checks: Int
    }

    /// Wait for the page to be fully ready
    /// Checks: document.readyState, DOM stability (no mutations), network idle
    /// - Parameters:
    ///   - timeout: Maximum time to wait (default 10s)
    ///   - stabilityMs: How long DOM/network must be stable (default 500ms)
    ///   - requiredSelector: Optional selector that must exist
    /// - Returns: PageReadyResult with details about what was detected
    func waitForReady(
        timeout: TimeInterval = 10,
        stabilityMs: Int = 500,
        requiredSelector: String? = nil
    ) async throws -> PageReadyResult {
        let startTime = Date()
        var checks = 0

        // Inject the page ready detection script once
        let setupScript = """
        (function() {
            if (window.__pageReadyState) return;

            window.__pageReadyState = {
                lastMutation: Date.now(),
                lastNetwork: Date.now(),
                pendingRequests: 0,
                mutations: 0
            };

            // Track DOM mutations
            const observer = new MutationObserver(() => {
                window.__pageReadyState.lastMutation = Date.now();
                window.__pageReadyState.mutations++;
            });
            observer.observe(document.body || document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
            });

            // Track network requests via fetch
            const origFetch = window.fetch;
            window.fetch = function(...args) {
                window.__pageReadyState.pendingRequests++;
                window.__pageReadyState.lastNetwork = Date.now();
                return origFetch.apply(this, args).finally(() => {
                    window.__pageReadyState.pendingRequests--;
                    window.__pageReadyState.lastNetwork = Date.now();
                });
            };

            // Track XMLHttpRequest
            const origOpen = XMLHttpRequest.prototype.open;
            const origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(...args) {
                this.__tracked = true;
                return origOpen.apply(this, args);
            };
            XMLHttpRequest.prototype.send = function(...args) {
                if (this.__tracked) {
                    window.__pageReadyState.pendingRequests++;
                    window.__pageReadyState.lastNetwork = Date.now();
                    this.addEventListener('loadend', () => {
                        window.__pageReadyState.pendingRequests--;
                        window.__pageReadyState.lastNetwork = Date.now();
                    });
                }
                return origSend.apply(this, args);
            };
        })();
        """
        _ = try? await evaluateJavaScript(setupScript)

        // Check function
        let selectorCheck = requiredSelector.map { "document.querySelector('\($0.escapedForJS)') !== null" } ?? "true"

        while Date().timeIntervalSince(startTime) < timeout {
            checks += 1

            let checkScript = """
            (function() {
                const state = window.__pageReadyState || { lastMutation: 0, lastNetwork: 0, pendingRequests: 0 };
                const now = Date.now();
                const stabilityMs = \(stabilityMs);

                const readyState = document.readyState;
                const domStable = (now - state.lastMutation) >= stabilityMs;
                const networkIdle = state.pendingRequests === 0 && (now - state.lastNetwork) >= stabilityMs;
                const selectorFound = \(selectorCheck);

                return {
                    readyState: readyState,
                    domStable: domStable,
                    networkIdle: networkIdle,
                    selectorFound: selectorFound,
                    pendingRequests: state.pendingRequests,
                    msSinceMutation: now - state.lastMutation,
                    msSinceNetwork: now - state.lastNetwork,
                    ready: readyState === 'complete' && domStable && networkIdle && selectorFound
                };
            })();
            """

            if let result = try? await evaluateJavaScript(checkScript) as? [String: Any],
               let ready = result["ready"] as? Bool,
               ready {
                let waitedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                return PageReadyResult(
                    ready: true,
                    readyState: result["readyState"] as? String ?? "unknown",
                    domStable: result["domStable"] as? Bool ?? false,
                    networkIdle: result["networkIdle"] as? Bool ?? false,
                    waitedMs: waitedMs,
                    checks: checks
                )
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 100ms between checks
        }

        // Timeout - return current state
        let waitedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        return PageReadyResult(
            ready: false,
            readyState: "timeout",
            domStable: false,
            networkIdle: false,
            waitedMs: waitedMs,
            checks: checks
        )
    }

    /// Resolve a selector chain, trying each selector in order
    /// Returns the first matching selector and its extracted value
    func resolveSelector(_ chain: SelectorChain, extract: String = "textContent") async -> ExtractionResult {
        var attempts = 0

        // Try each selector in the chain
        for (index, selector) in chain.chain.enumerated() {
            attempts += 1
            let escapedSelector = selector.escapedForJS

            let script = """
            (function() {
                const el = document.querySelector('\(escapedSelector)');
                if (!el) return null;
                return el.\(extract)?.trim() || null;
            })();
            """

            if let value = try? await evaluateJavaScript(script), !(value is NSNull) {
                let transformedValue = applyTransform(value, chain.transform)
                return ExtractionResult(
                    value: transformedValue,
                    selectorUsed: selector,
                    wasFallback: index > 0,
                    attempts: attempts,
                    success: true
                )
            }
        }

        // Try fallback script if all selectors failed
        if let fallbackScript = chain.fallbackScript {
            attempts += 1
            if let value = try? await evaluateJavaScript(fallbackScript), !(value is NSNull) {
                let transformedValue = applyTransform(value, chain.transform)
                return ExtractionResult(
                    value: transformedValue,
                    selectorUsed: "fallbackScript",
                    wasFallback: true,
                    attempts: attempts,
                    success: true
                )
            }
        }

        return ExtractionResult(
            value: nil,
            selectorUsed: "none",
            wasFallback: true,
            attempts: attempts,
            success: false
        )
    }

    /// Apply a JavaScript transform to a value
    private func applyTransform(_ value: Any?, _ transform: String?) -> Any? {
        guard let transform = transform, let value = value else {
            return value
        }

        // Simple transforms we can do in Swift
        if let str = value as? String {
            if transform.contains("trim()") {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if transform.contains("split('\\n')[0]") {
                return str.components(separatedBy: "\n").first ?? str
            }
            if transform.contains("parseFloat") {
                let cleaned = str.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
                return Double(cleaned)
            }
        }

        return value
    }

    /// Execute with retry strategies
    func executeWithRetry(
        action: @escaping () async throws -> Any?,
        strategies: [RetryStrategy],
        maxAttempts: Int = 3
    ) async throws -> Any? {
        var lastError: Error?
        var attempt = 0

        // First attempt without any strategy
        do {
            return try await action()
        } catch {
            lastError = error
        }

        // Retry with each strategy
        for strategy in strategies {
            attempt += 1
            if attempt > maxAttempts { break }

            // Apply retry strategy
            switch strategy {
            case .scroll:
                _ = try? await evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight / 2)")
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms

            case .wait:
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2s

            case .reload:
                reload()
                _ = await waitForNavigation()

            case .viewport:
                // Not implemented for iOS - would need simulator resize
                break
            }

            // Retry the action
            do {
                return try await action()
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? BrowserError.timeout("Retry exhausted")
    }

    /// Capture failure artifacts for debugging
    func captureFailureArtifacts(
        failedSelector: String,
        triedSelectors: [String],
        error: String
    ) async -> FailureArtifacts {
        async let screenshot = try? takeScreenshot()
        async let pdf = try? takeFullPageScreenshot()
        async let dom = getDOMSnapshot()

        return FailureArtifacts(
            screenshot: await screenshot,
            fullPagePdf: await pdf,
            domSnapshot: await dom,
            failedSelector: failedSelector,
            triedSelectors: triedSelectors,
            timestamp: Date(),
            error: error
        )
    }

    /// Get a snapshot of the current DOM
    func getDOMSnapshot() async -> String? {
        let script = "document.documentElement.outerHTML"
        return try? await evaluateJavaScript(script) as? String
    }

    /// Get console logs (if available)
    func getConsoleLogs() async -> [String] {
        // Note: This would require injecting a console capture script earlier
        // For now, return empty array
        return []
    }

    // MARK: - Extraction V2: Production-Safe

    /// Check if an element exists on the page
    func elementExists(_ selector: String) async -> Bool {
        let script = "document.querySelector('\(selector.escapedForJS)') !== null"
        return (try? await evaluateJavaScript(script) as? Bool) ?? false
    }

    /// Validate the current page against rules
    func validatePage(_ rules: PageValidationRules) async -> PageValidationResult {
        var checks: [PageValidationResult.ValidationCheck] = []
        var failedChecks: [String] = []

        let urlString = currentURL?.absoluteString.lowercased() ?? ""
        let title = pageTitle.lowercased()

        // URL contains check
        if let urlContains = rules.urlContains {
            let passed = urlContains.allSatisfy { urlString.contains($0.lowercased()) }
            checks.append(.init(name: "urlContains", passed: passed,
                expected: urlContains.joined(separator: ", "), actual: urlString))
            if !passed { failedChecks.append("URL missing required pattern") }
        }

        // URL not contains (detect redirects/errors)
        if let urlNotContains = rules.urlNotContains {
            let passed = !urlNotContains.contains { urlString.contains($0.lowercased()) }
            checks.append(.init(name: "urlNotContains", passed: passed,
                expected: "none of: \(urlNotContains.joined(separator: ", "))", actual: urlString))
            if !passed { failedChecks.append("URL contains forbidden pattern (redirect/error?)") }
        }

        // Title contains (product verification)
        if let titleContains = rules.titleContains {
            let passed = titleContains.contains { title.contains($0.lowercased()) }
            checks.append(.init(name: "titleContains", passed: passed,
                expected: "any of: \(titleContains.joined(separator: ", "))", actual: pageTitle))
            if !passed { failedChecks.append("Page title missing expected keywords") }
        }

        // Title not contains (error pages)
        if let titleNotContains = rules.titleNotContains {
            let passed = !titleNotContains.contains { title.contains($0.lowercased()) }
            checks.append(.init(name: "titleNotContains", passed: passed,
                expected: "none of: \(titleNotContains.joined(separator: ", "))", actual: pageTitle))
            if !passed { failedChecks.append("Page appears to be error/captcha page") }
        }

        // Required elements
        if let required = rules.requiredElements {
            for selector in required {
                let exists = await elementExists(selector)
                checks.append(.init(name: "required:\(selector)", passed: exists,
                    expected: "exists", actual: exists ? "found" : "missing"))
                if !exists { failedChecks.append("Required element missing: \(selector)") }
            }
        }

        // Forbidden elements (captcha, blocks)
        if let forbidden = rules.forbiddenElements {
            for selector in forbidden {
                let exists = await elementExists(selector)
                let passed = !exists
                checks.append(.init(name: "forbidden:\(selector)", passed: passed,
                    expected: "not present", actual: exists ? "FOUND" : "not found"))
                if !passed { failedChecks.append("Forbidden element detected: \(selector)") }
            }
        }

        return PageValidationResult(passed: failedChecks.isEmpty, checks: checks, failedChecks: failedChecks)
    }

    /// Extract and rank all price candidates from the page
    func extractPriceCandidates(ranking: CandidateRankingConfig?) async -> [ExtractionCandidate] {
        let config = ranking ?? .default

        // JavaScript to find all prices with context using matchAll
        let script = """
        (function() {
            const prices = [];
            const text = document.body.innerText;
            const matches = [...text.matchAll(/\\$([0-9]{1,4}\\.?[0-9]{0,2})/g)];

            matches.slice(0, 20).forEach((match, index) => {
                const start = Math.max(0, match.index - 50);
                const end = Math.min(text.length, match.index + match[0].length + 50);
                const context = text.substring(start, end).toLowerCase();

                prices.push({
                    value: parseFloat(match[1]),
                    position: index,
                    context: context
                });
            });
            return prices;
        })();
        """

        guard let results = try? await evaluateJavaScript(script) as? [[String: Any]] else {
            return []
        }

        var candidates: [ExtractionCandidate] = []

        for data in results {
            guard let value = data["value"] as? Double,
                  let position = data["position"] as? Int,
                  let context = data["context"] as? String else { continue }

            var score: Double = 0.5
            var reasoning: [String] = []

            // Range preference
            if let range = config.preferRange, range.count >= 2 {
                if value >= range[0] && value <= range[1] {
                    score += 0.2
                    reasoning.append("+0.2: in expected range")
                } else {
                    score -= config.penalizeOutsideRange ?? 0.3
                    reasoning.append("-\(config.penalizeOutsideRange ?? 0.3): outside range")
                }
            }

            // Avoid bad context (shipping, tax, was)
            if let avoid = config.avoidContextPatterns {
                for pattern in avoid {
                    if context.contains(pattern.lowercased()) {
                        score -= config.avoidContextPenalty ?? 0.2
                        reasoning.append("-\(config.avoidContextPenalty ?? 0.2): near '\(pattern)'")
                        break
                    }
                }
            }

            // Prefer good context (add to cart, price)
            if let prefer = config.preferContextPatterns {
                for pattern in prefer {
                    if context.contains(pattern.lowercased()) {
                        score += config.preferContextBonus ?? 0.15
                        reasoning.append("+\(config.preferContextBonus ?? 0.15): near '\(pattern)'")
                        break
                    }
                }
            }

            // Position bonus
            if position == 0 {
                score += 0.1
                reasoning.append("+0.1: first price on page")
            }

            candidates.append(ExtractionCandidate(
                value: value,
                source: "regex",
                score: max(0, min(1, score)),
                context: context,
                position: position,
                reasoning: reasoning
            ))
        }

        return candidates.sorted { $0.score > $1.score }
    }

    /// Production-safe extraction with page validation, selector chain, and candidate ranking
    func resolveSelectorV2(
        chain: SelectorChainV2,
        pageValidation: PageValidationRules?,
        valueValidation: ValidationRule?
    ) async -> ExtractionResultV2 {
        var validationErrors: [String] = []

        // LAYER 1: Page Validation
        let pageResult: PageValidationResult
        if let rules = pageValidation {
            pageResult = await validatePage(rules)
            if !pageResult.passed {
                return ExtractionResultV2(
                    value: nil,
                    confidence: 0,
                    method: .failed,
                    selectorUsed: nil,
                    candidates: nil,
                    validationErrors: pageResult.failedChecks,
                    pageValidation: pageResult,
                    artifacts: nil
                )
            }
        } else {
            pageResult = .skipped
        }

        // LAYER 2: Selector Chain
        for (index, selector) in chain.chain.enumerated() {
            let script = """
            (function() {
                const el = document.querySelector('\(selector.escapedForJS)');
                if (!el) return null;
                return el.textContent?.trim() || el.innerText?.trim() || null;
            })();
            """

            if let rawValue = try? await evaluateJavaScript(script),
               !(rawValue is NSNull),
               let stringValue = rawValue as? String,
               !stringValue.isEmpty {

                let transformed = applyTransform(stringValue, chain.transform)

                // Calculate confidence
                let confidence: Double
                switch index {
                case 0: confidence = ConfidenceLevel.primarySelector
                case 1: confidence = ConfidenceLevel.secondarySelector
                default: confidence = ConfidenceLevel.tertiarySelector
                }

                // Value validation
                if let validation = valueValidation {
                    let result = validation.validate(transformed)
                    if !result.isValid, let msg = result.message {
                        validationErrors.append(msg)
                    }
                }

                return ExtractionResultV2(
                    value: AnyCodable(transformed),
                    confidence: validationErrors.isEmpty ? confidence : confidence * 0.5,
                    method: index == 0 ? .primarySelector : .fallbackSelector,
                    selectorUsed: selector,
                    candidates: nil,
                    validationErrors: validationErrors,
                    pageValidation: pageResult,
                    artifacts: nil
                )
            }
        }

        // LAYER 3: Regex Fallback with Candidate Ranking
        if chain.fallbackPattern != nil {
            let candidates = await extractPriceCandidates(ranking: chain.fallbackRanking)

            if let best = candidates.first {
                let transformed = applyTransform(best.value, chain.transform)

                let confidence = candidates.count > 1
                    ? ConfidenceLevel.regexRanked * best.score
                    : ConfidenceLevel.regexFirst * best.score

                // Value validation
                if let validation = valueValidation {
                    let result = validation.validate(transformed)
                    if !result.isValid, let msg = result.message {
                        validationErrors.append(msg)
                    }
                }

                return ExtractionResultV2(
                    value: AnyCodable(transformed),
                    confidence: validationErrors.isEmpty ? confidence : confidence * 0.5,
                    method: candidates.count > 1 ? .regexRanked : .regexFallback,
                    selectorUsed: "regex",
                    candidates: Array(candidates.prefix(5)),
                    validationErrors: validationErrors,
                    pageValidation: pageResult,
                    artifacts: nil
                )
            }
        }

        // FAILED
        return ExtractionResultV2(
            value: nil,
            confidence: 0,
            method: .failed,
            selectorUsed: nil,
            candidates: nil,
            validationErrors: ["No selector matched and fallback failed"],
            pageValidation: pageResult,
            artifacts: nil
        )
    }
}

// MARK: - Navigation Delegate

class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var controller: BrowserController?

    init(controller: BrowserController) {
        self.controller = controller
        super.init()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            controller?.isLoading = true
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            controller?.isLoading = false
            controller?.currentURL = webView.url
            controller?.pageTitle = webView.title ?? ""
            controller?.canGoBack = webView.canGoBack
            controller?.canGoForward = webView.canGoForward
            controller?.navigationDidFinish()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            controller?.isLoading = false
            controller?.navigationDidFail()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            controller?.isLoading = false
            controller?.navigationDidFail()
        }
    }
}

/// MARK: - Vision Capture Model

/// Data structure for vision-based automation captures
struct VisionCapture {
    let pdf: Data           // Full page PDF data
    let url: String         // Current page URL
    let title: String       // Page title
    let timestamp: Date     // Capture timestamp
}

// MARK: - Errors

enum BrowserError: LocalizedError {
    case invalidURL
    case elementNotFound(String)
    case noEditableElement
    case timeout(String)
    case javascriptError(String)
    case selectorChainExhausted([String])
    case screenshotFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .elementNotFound(let selector):
            return "Element not found: \(selector)"
        case .noEditableElement:
            return "No editable element is focused"
        case .timeout(let message):
            return "Timeout: \(message)"
        case .javascriptError(let message):
            return "JavaScript error: \(message)"
        case .selectorChainExhausted(let selectors):
            return "No selector matched: \(selectors.joined(separator: ", "))"
        case .screenshotFailed:
            return "Failed to capture screenshot"
        }
    }
}

// MARK: - String Extension

extension String {
    var escapedForJS: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Sendable Value Wrapper

/// Wrapper to make Any? values Sendable across async boundaries
/// Used for JavaScript evaluation results
struct SendableValue: @unchecked Sendable {
    let value: Any?

    init(_ value: Any?) {
        self.value = value
    }
}
