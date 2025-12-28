import Foundation

// MARK: - Playwright Usage Examples

/// Examples demonstrating how to use PlaywrightController for iOS Simulator automation
enum PlaywrightExamples {

    // MARK: - Basic Navigation

    /// Navigate to a website and take a screenshot
    static func basicNavigation() async throws {
        let playwright = PlaywrightController.shared

        // Launch browser in simulator (boots simulator if needed)
        try await playwright.launch()

        // Navigate to a URL
        try await playwright.goto("https://example.com")

        // Get page info
        let title: String = try await playwright.evaluate("document.title")
        let url = try await playwright.url()
        print("Page: \(title) at \(url)")

        // Take a screenshot of the WebView content
        let webScreenshot = try await playwright.screenshot()

        // Take a screenshot of the entire simulator
        let simScreenshot = try await playwright.screenshotSimulator()

        // Save screenshots
        try webScreenshot.write(to: URL(fileURLWithPath: "/tmp/web-screenshot.png"))
        try simScreenshot.write(to: URL(fileURLWithPath: "/tmp/sim-screenshot.png"))
    }

    // MARK: - Form Interaction

    /// Fill out a login form
    static func loginExample() async throws {
        let playwright = PlaywrightController.shared

        try await playwright.launch()
        try await playwright.goto("https://example.com/login")

        // Wait for the form to load
        try await playwright.waitForSelector("input[name='email']")

        // Fill form fields using JavaScript bridge
        try await playwright.fill("input[name='email']", value: "user@example.com")
        try await playwright.fill("input[name='password']", value: "secretpassword")

        // Click the submit button
        try await playwright.click("button[type='submit']")

        // Wait for navigation
        try await playwright.waitForNavigation()

        // Save cookies for later sessions
        try await playwright.saveCookies(for: "example.com")
    }

    // MARK: - Using Saved Cookies

    /// Load saved cookies to skip login
    static func loadSessionExample() async throws {
        let playwright = PlaywrightController.shared

        try await playwright.launch()

        // Load previously saved cookies
        try await playwright.loadCookies(for: "example.com")

        // Navigate - should be logged in already
        try await playwright.goto("https://example.com/dashboard")

        // Verify we're logged in
        let isLoggedIn: Bool = try await playwright.evaluate(
            "document.querySelector('.user-profile') !== null"
        )
        print("Logged in: \(isLoggedIn)")
    }

    // MARK: - Simulator-Level Interactions (AXe)

    /// Use AXe for physical simulator interactions
    static func simulatorInteractions() async throws {
        let playwright = PlaywrightController.shared

        try await playwright.launch()
        try await playwright.goto("https://example.com")

        // Tap at specific coordinates
        try await playwright.simulatorTap(x: 200, y: 400)

        // Tap by accessibility label (for native UI elements)
        try await playwright.simulatorTap(label: "Go")

        // Type using simulator keyboard (useful for native inputs)
        try await playwright.simulatorType("Hello World")

        // Scroll down using gesture preset
        try await playwright.simulatorGesture(.scrollDown)

        // Swipe with custom coordinates
        try await playwright.simulatorSwipe(
            startX: 200, startY: 600,
            endX: 200, endY: 200,
            duration: 0.5
        )

        // Press hardware buttons
        try await playwright.simulatorButton(.home)

        // Get UI accessibility tree (useful for debugging)
        let uiTree = try await playwright.describeUI()
        print("UI Tree:\n\(uiTree)")
    }

    // MARK: - JavaScript Evaluation

    /// Execute JavaScript in the page context
    static func javascriptExample() async throws {
        let playwright = PlaywrightController.shared

        try await playwright.launch()
        try await playwright.goto("https://example.com")

        // Get page title
        let title: String = try await playwright.evaluate("document.title")

        // Get all links on the page
        let linkCount: Int = try await playwright.evaluate(
            "document.querySelectorAll('a').length"
        )

        // Scroll to bottom
        try await playwright.evaluate("window.scrollTo(0, document.body.scrollHeight)")

        // Get element text
        let heading: String = try await playwright.evaluate(
            "document.querySelector('h1')?.textContent || 'No heading'"
        )

        print("Title: \(title), Links: \(linkCount), Heading: \(heading)")
    }

    // MARK: - Element Queries

    /// Query and interact with DOM elements
    static func elementQueryExample() async throws {
        let playwright = PlaywrightController.shared

        try await playwright.launch()
        try await playwright.goto("https://example.com")

        // Query single element
        if let heading = try await playwright.querySelector("h1") {
            print("Found heading: \(heading.textContent ?? "no text")")
            print("Tag: \(heading.tagName)")
            if let rect = heading.boundingRect {
                print("Position: \(rect)")
            }
        }

        // Query multiple elements
        let links = try await playwright.querySelectorAll("a")
        print("Found \(links.count) links")

        for link in links {
            if let href = link.attributes["href"] {
                print("  - \(href)")
            }
        }
    }

    // MARK: - Social Media Automation Example

    /// Example: Automate posting to a social platform
    static func socialMediaExample() async throws {
        let playwright = PlaywrightController.shared

        try await playwright.launch()

        // Try to load existing session
        try await playwright.loadCookies(for: "instagram.com")
        try await playwright.goto("https://instagram.com")

        // Check if logged in
        let isLoggedIn: Bool = try await playwright.evaluate(
            "document.querySelector('[aria-label=\"Home\"]') !== null"
        )

        if !isLoggedIn {
            // Need to login
            try await playwright.waitForSelector("input[name='username']")
            try await playwright.fill("input[name='username']", value: "myusername")
            try await playwright.fill("input[name='password']", value: "mypassword")
            try await playwright.click("button[type='submit']")
            try await playwright.waitForNavigation()

            // Save session for next time
            try await playwright.saveCookies(for: "instagram.com")
        }

        // Now interact with the feed
        try await playwright.simulatorGesture(.scrollDown)

        // Take a screenshot
        let screenshot = try await playwright.screenshotSimulator()
        try screenshot.write(to: URL(fileURLWithPath: "/tmp/instagram-feed.png"))
    }

    // MARK: - Error Handling

    /// Proper error handling example
    static func errorHandlingExample() async {
        let playwright = PlaywrightController.shared

        do {
            try await playwright.launch()
            try await playwright.goto("https://example.com")

            // This might fail if element doesn't exist
            try await playwright.waitForSelector(".nonexistent", timeout: 5)

        } catch PlaywrightError.timeout(let message) {
            print("Timeout: \(message)")
        } catch PlaywrightError.elementNotFound(let selector) {
            print("Element not found: \(selector)")
        } catch PlaywrightError.notConnected {
            print("Not connected to browser")
        } catch PlaywrightError.axeCommandFailed(let cmd, let error) {
            print("AXe command '\(cmd)' failed: \(error)")
        } catch {
            print("Unexpected error: \(error)")
        }
    }

    // MARK: - Cleanup

    /// Proper cleanup when done
    static func cleanupExample() async throws {
        let playwright = PlaywrightController.shared

        try await playwright.launch()

        // Do your automation...
        try await playwright.goto("https://example.com")

        // Always close when done
        defer {
            Task {
                try? await playwright.close()
            }
        }

        // Your automation code here...
    }
}

// MARK: - Quick Start

/*
 Quick Start Guide:

 1. Build and run AtlBrowser in the simulator first:
    - Open AtlBrowser.xcworkspace
    - Select an iOS Simulator
    - Build and Run (Cmd+R)

 2. Use PlaywrightController in your code:

    ```swift
    let playwright = PlaywrightController.shared

    // Launch (connects to running AtlBrowser)
    try await playwright.launch(simulator: "YOUR-SIMULATOR-UDID")

    // Navigate
    try await playwright.goto("https://example.com")

    // Interact via JavaScript bridge
    try await playwright.click("button.submit")
    try await playwright.fill("input[name='search']", value: "query")

    // Or use simulator-level interactions
    try await playwright.simulatorTap(x: 200, y: 300)
    try await playwright.simulatorType("Hello")

    // Screenshot
    let screenshot = try await playwright.screenshotSimulator()

    // Close when done
    try await playwright.close()
    ```

 3. Cookie persistence:
    - saveCookies(for: "domain.com") - saves to ~/Library/Application Support/Atl/Cookies/
    - loadCookies(for: "domain.com") - restores session
    - deleteSavedCookies(for: "domain.com") - removes saved cookies
*/
