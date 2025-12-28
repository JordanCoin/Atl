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

// MARK: - Errors

enum BrowserError: LocalizedError {
    case invalidURL
    case elementNotFound(String)
    case noEditableElement
    case timeout(String)
    case javascriptError(String)

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
