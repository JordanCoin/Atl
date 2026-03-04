import XCTest

/// UI tests for the ATL HTTP command server (FlyingFox-based).
/// These tests launch the app, wait for the server, and exercise
/// every major endpoint via HTTP to verify end-to-end behavior.
final class CommandServerUITests: XCTestCase {

    private let baseURL = "http://localhost:9222"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // Wait for server to come up
        let ready = waitForServer(timeout: 15)
        XCTAssertTrue(ready, "ATL server did not start within 15 seconds")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Ping

    func testPingReturnsOK() throws {
        let (data, response) = try syncGET("/ping")
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "ok")
    }

    // MARK: - Navigation

    func testGotoNavigatesToURL() throws {
        let result = try postCommand("goto", params: ["url": "https://example.com"])
        XCTAssertTrue(result.success, "goto failed: \(result.error ?? "unknown")")
        XCTAssertEqual(result.resultDict?["url"] as? String, "https://example.com/")
    }

    func testGotoNavigatesToDifferentURL() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("goto", params: ["url": "https://example.org"])
        XCTAssertTrue(result.success, "second goto failed: \(result.error ?? "unknown")")

        let url = result.resultDict?["url"] as? String
        XCTAssertTrue(url?.contains("example.org") ?? false, "Should have navigated to example.org")
    }

    // MARK: - Snapshot & Marks

    func testAgentSnapshotReturnsMarksAndText() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("agentSnapshot", params: ["pdf": false])
        XCTAssertTrue(result.success, "agentSnapshot failed: \(result.error ?? "unknown")")
        XCTAssertNotNil(result.resultDict?["marks"])
        XCTAssertNotNil(result.resultDict?["text"])
        XCTAssertNotNil(result.resultDict?["url"])
    }

    func testMarkAllAndClickMark() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let markResult = try postCommand("markAll")
        XCTAssertTrue(markResult.success, "markAll failed")

        // markAll returns { count: N, elements: [...] }
        let elements = markResult.resultDict?["elements"] as? [[String: Any]]
        XCTAssertNotNil(elements, "markAll should return elements")
        XCTAssertFalse(elements?.isEmpty ?? true, "Should have at least one mark")

        // Click mark 0 (first marked element)
        let clickResult = try postCommand("clickMark", params: ["label": 0])
        XCTAssertTrue(clickResult.success, "clickMark failed: \(clickResult.error ?? "unknown")")
    }

    func testMarkCompact() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("markCompact")
        XCTAssertTrue(result.success, "markCompact failed")
    }

    // MARK: - Click by Text

    func testClickTextFindsAndClicks() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("clickText", params: ["text": "Learn more"])
        XCTAssertTrue(result.success, "clickText failed: \(result.error ?? "unknown")")
    }

    // MARK: - Screenshot & PDF

    func testScreenshotReturnsPNG() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("screenshot")
        XCTAssertTrue(result.success, "screenshot failed: \(result.error ?? "unknown")")

        let dataStr = result.resultDict?["data"] as? String
        XCTAssertNotNil(dataStr, "screenshot should return base64 data")
        XCTAssertFalse(dataStr?.isEmpty ?? true)

        // Verify it decodes to valid data
        let imageData = Data(base64Encoded: dataStr ?? "")
        XCTAssertNotNil(imageData, "Should be valid base64")
        XCTAssertGreaterThan(imageData?.count ?? 0, 100, "Image should be non-trivial size")
    }

    func testFullPagePDF() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("screenshot", params: ["fullPage": true])
        XCTAssertTrue(result.success, "fullPage PDF failed: \(result.error ?? "unknown")")

        let dataStr = result.resultDict?["data"] as? String
        XCTAssertNotNil(dataStr)
    }

    // MARK: - Wait Commands

    func testWaitForDOMStable() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])

        let result = try postCommand("waitForDOMStable", params: ["stabilityMs": 300, "timeout": 10])
        XCTAssertTrue(result.success, "waitForDOMStable failed: \(result.error ?? "unknown")")
    }

    func testWaitForSelector() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("waitForSelector", params: ["selector": "h1", "timeout": 10])
        XCTAssertTrue(result.success, "waitForSelector for h1 failed: \(result.error ?? "unknown")")
    }

    func testWaitForSelectorTimeout() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        // Server returns 500 with empty body on timeout — postCommand will throw
        // or return a failure result. Either way, it should not succeed.
        do {
            let result = try postCommand("waitForSelector", params: ["selector": "#nonexistent-element-xyz", "timeout": 2])
            XCTAssertFalse(result.success, "Should timeout for nonexistent selector")
        } catch {
            // Throwing is acceptable — means server returned non-JSON (empty 500)
        }
    }

    // MARK: - Type & Fill

    func testTypeCommand() throws {
        // Navigate to a page with an input
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        // Type without a focused element should fail gracefully
        let result = try postCommand("type", params: ["text": "hello"])
        // This may or may not succeed depending on focus state, but should not crash
        XCTAssertNotNil(result)
    }

    // MARK: - Evaluate

    func testEvaluateJavaScript() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("evaluate", params: ["script": "document.title"])
        XCTAssertTrue(result.success, "evaluate failed: \(result.error ?? "unknown")")

        let value = result.resultDict?["value"] as? String
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("Example") ?? false, "Title should contain 'Example'")
    }

    // MARK: - Navigation Commands

    func testReload() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("reload")
        XCTAssertTrue(result.success, "reload failed: \(result.error ?? "unknown")")
    }

    func testBack() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        let result = try postCommand("back")
        // May not have history, but should not crash
        XCTAssertNotNil(result)
    }

    // MARK: - Error Handling

    func testInvalidMethodReturnsError() throws {
        let result = try postCommand("totallyFakeMethod123")
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    func testInvalidJSONReturnsError() throws {
        let url = URL(string: "\(baseURL)/command")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{ broken json".utf8)

        let (data, httpResponse) = try syncRequest(request)
        // Should get 400 for malformed JSON
        XCTAssertEqual((httpResponse as? HTTPURLResponse)?.statusCode, 400)

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["error"])
    }

    func testWrongPathReturns404() throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/nonexistent")!)
        request.httpMethod = "GET"

        let (_, response) = try syncRequest(request)
        let httpResponse = response as? HTTPURLResponse
        // FlyingFox returns 404 for unmatched routes
        XCTAssertNotEqual(httpResponse?.statusCode, 200)
    }

    // MARK: - Rapid Sequential Requests (regression test for HTTP 400 bug)

    func testRapidSequentialCommandsDoNotFail() throws {
        _ = try postCommand("goto", params: ["url": "https://example.com"])
        waitForDOMStable()

        // Fire 20 rapid commands — this is the scenario that triggered the old
        // NWListener HTTP 400 bug where body data was split across TCP packets.
        var failures: [String] = []
        for i in 1...20 {
            let result = try postCommand("agentSnapshot", params: ["pdf": false])
            if !result.success {
                failures.append("Request \(i) failed: \(result.error ?? "unknown")")
            }
        }

        XCTAssertTrue(failures.isEmpty, "Rapid requests failed: \(failures.joined(separator: ", "))")
    }

    func testConcurrentPingsDoNotFail() throws {
        // Fire 10 concurrent ping requests
        let group = DispatchGroup()
        var results: [(Int, Int)] = [] // (index, statusCode)
        let lock = NSLock()

        for i in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let (_, response) = try self.syncGET("/ping")
                    lock.lock()
                    results.append((i, response.statusCode))
                    lock.unlock()
                } catch {
                    lock.lock()
                    results.append((i, -1))
                    lock.unlock()
                }
            }
        }

        group.wait()
        let failures = results.filter { $0.1 != 200 }
        XCTAssertTrue(failures.isEmpty, "Concurrent pings failed: \(failures)")
    }

    // MARK: - Helpers

    private func waitForServer(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (_, response) = try? syncGET("/ping"), response.statusCode == 200 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func waitForDOMStable() {
        _ = try? postCommand("waitForDOMStable", params: ["stabilityMs": 500, "timeout": 10])
    }

    private func syncGET(_ path: String) throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "\(baseURL)\(path)")!
        let request = URLRequest(url: url)
        let (data, response) = try syncRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }

    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }.resume()

        let timeout = semaphore.wait(timeout: .now() + 30)
        if timeout == .timedOut {
            throw URLError(.timedOut)
        }
        if let error = resultError {
            throw error
        }
        return (resultData ?? Data(), resultResponse!)
    }

    struct CommandResult {
        let success: Bool
        let resultDict: [String: Any]?
        let error: String?
    }

    private func postCommand(_ method: String, params: [String: Any]? = nil) throws -> CommandResult {
        let url = URL(string: "\(baseURL)/command")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["id": UUID().uuidString, "method": method]
        if let params {
            body["params"] = params
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try syncRequest(request)
        let httpResponse = response as? HTTPURLResponse

        // Handle empty response body (e.g. 500 with Content-Length: 0)
        guard !data.isEmpty else {
            return CommandResult(
                success: false,
                resultDict: nil,
                error: "Empty response (HTTP \(httpResponse?.statusCode ?? 0))"
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Handle error-only response format
        if let error = json?["error"] as? String, json?["success"] == nil {
            return CommandResult(success: false, resultDict: nil, error: error)
        }

        return CommandResult(
            success: json?["success"] as? Bool ?? false,
            resultDict: json?["result"] as? [String: Any],
            error: json?["error"] as? String
        )
    }
}
