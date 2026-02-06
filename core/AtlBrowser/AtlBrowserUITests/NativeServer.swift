import XCTest
import Foundation
import Network

/// Native app automation server that runs as a UI Test
/// This gives us access to XCUIApplication and XCUIElement APIs
final class NativeServer: XCTestCase {
    
    private var listener: NWListener?
    private var isRunning = false
    
    // Currently controlled app
    private var currentApp: XCUIApplication?
    private var currentBundleId: String?
    
    // Element refs from last snapshot
    private var elementRefs: [String: XCUIElement] = [:]
    private let maxElements = 500
    
    override func setUpWithError() throws {
        continueAfterFailure = true
    }
    
    override func tearDownWithError() throws {
        stopServer()
    }
    
    /// Main test that runs the native automation server
    @MainActor
    func testNativeServer() throws {
        startServer(port: 9223)
        
        // Keep test running indefinitely
        print("[NativeServer] Running on port 9223...")
        print("[NativeServer] Press Ctrl+C to stop")
        
        // Use expectation to keep test alive (1 hour timeout)
        let expectation = XCTestExpectation(description: "Server running")
        
        // This will wait for up to 1 hour
        let result = XCTWaiter.wait(for: [expectation], timeout: 3600)
        
        // If we get here, server was stopped
        if result == .timedOut {
            print("[NativeServer] Server timed out after 1 hour")
        }
    }
    
    // MARK: - Server
    
    private func startServer(port: UInt16) {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                print("[NativeServer] Invalid port: \(port)")
                return
            }
            
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: parameters, on: nwPort)
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[NativeServer] Listening on port \(port)")
                    self?.isRunning = true
                case .failed(let error):
                    print("[NativeServer] Failed: \(error)")
                    self?.isRunning = false
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .main)
        } catch {
            print("[NativeServer] Error: \(error)")
        }
    }
    
    private func stopServer() {
        isRunning = false
        listener?.cancel()
        listener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveRequest(connection)
            }
        }
        connection.start(queue: .main)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleRequest(data, connection: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }
    
    private func handleRequest(_ data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendError(connection, message: "Invalid request")
            return
        }
        
        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(connection, message: "Empty request")
            return
        }
        
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendError(connection, message: "Invalid request line")
            return
        }
        
        let method = String(parts[0])
        let path = String(parts[1])
        
        // Find body
        var body: Data?
        if let emptyLineIndex = lines.firstIndex(of: "") {
            let bodyStart = emptyLineIndex + 1
            if bodyStart < lines.count {
                let bodyString = lines[bodyStart...].joined(separator: "\r\n")
                body = bodyString.data(using: .utf8)
            }
        }
        
        // Route
        if path == "/ping" && method == "GET" {
            sendJSON(connection, json: ["status": "ok", "mode": "native"])
        } else if path == "/command" && method == "POST" {
            handleCommand(body, connection: connection)
        } else {
            sendError(connection, message: "Not found")
        }
    }
    
    private func handleCommand(_ body: Data?, connection: NWConnection) {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let commandMethod = json["method"] as? String else {
            sendError(connection, message: "Invalid command")
            return
        }
        
        let id = json["id"] as? String ?? "0"
        let params = json["params"] as? [String: Any] ?? [:]
        
        do {
            let result = try executeCommand(method: commandMethod, params: params)
            sendSuccess(connection, id: id, result: result)
        } catch {
            sendFailure(connection, id: id, error: error.localizedDescription)
        }
    }
    
    private func executeCommand(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "openApp":
            guard let bundleId = params["bundleId"] as? String else {
                throw NativeError.missingParam("bundleId")
            }
            return try openApp(bundleId: bundleId)
            
        case "closeApp":
            let bundleId = params["bundleId"] as? String
            try closeApp(bundleId: bundleId)
            return ["closed": true]
            
        case "appState":
            return appState()
            
        case "snapshot":
            let interactiveOnly = params["interactiveOnly"] as? Bool ?? false
            let maxDepth = params["maxDepth"] as? Int
            return try snapshot(interactiveOnly: interactiveOnly, maxDepth: maxDepth)
            
        case "tapRef":
            guard let ref = params["ref"] as? String else {
                throw NativeError.missingParam("ref")
            }
            try tapRef(ref: ref)
            return ["tapped": ref]
            
        case "find":
            guard let text = params["text"] as? String else {
                throw NativeError.missingParam("text")
            }
            let action = params["action"] as? String ?? "exists"
            let value = params["value"] as? String
            return try find(text: text, action: action, value: value)
            
        case "tap":
            let x = params["x"] as? Double ?? 0
            let y = params["y"] as? Double ?? 0
            try tap(x: x, y: y)
            return ["tapped": true, "x": x, "y": y]
            
        case "swipe":
            if let direction = params["direction"] as? String {
                try swipe(direction: direction)
                return ["swiped": direction]
            } else {
                throw NativeError.missingParam("direction")
            }
            
        case "screenshot":
            let data = try screenshot()
            return ["data": data, "format": "png"]
            
        default:
            throw NativeError.unknownCommand(method)
        }
    }
    
    // MARK: - Native Commands
    
    private func openApp(bundleId: String) throws -> [String: Any] {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.launch()
        
        // Wait for app to be running
        let launched = app.wait(for: .runningForeground, timeout: 10)
        
        if !launched {
            throw NativeError.appLaunchFailed(bundleId)
        }
        
        currentApp = app
        currentBundleId = bundleId
        elementRefs.removeAll()
        
        return [
            "bundleId": bundleId,
            "mode": "native",
            "state": "running"
        ]
    }
    
    private func closeApp(bundleId: String?) throws {
        let targetBundle = bundleId ?? currentBundleId
        
        guard let bundle = targetBundle else {
            throw NativeError.noAppOpen
        }
        
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.terminate()
        
        if bundle == currentBundleId {
            currentApp = nil
            currentBundleId = nil
            elementRefs.removeAll()
        }
    }
    
    private func appState() -> [String: Any] {
        guard let bundleId = currentBundleId else {
            return ["mode": "native", "bundleId": NSNull(), "state": "none"]
        }
        
        let state: String
        if let app = currentApp {
            switch app.state {
            case .runningForeground:
                state = "running"
            case .runningBackground, .runningBackgroundSuspended:
                state = "suspended"
            default:
                state = "terminated"
            }
        } else {
            state = "none"
        }
        
        return ["mode": "native", "bundleId": bundleId, "state": state]
    }
    
    private func snapshot(interactiveOnly: Bool, maxDepth: Int?) throws -> [String: Any] {
        guard let app = currentApp else {
            throw NativeError.noAppOpen
        }
        
        elementRefs.removeAll()
        var elements: [[String: Any]] = []
        var refIndex = 0
        
        let allElements = app.descendants(matching: .any).allElementsBoundByIndex
        
        for element in allElements {
            guard elements.count < maxElements else { break }
            
            if interactiveOnly && !element.isHittable {
                continue
            }
            
            let label = element.label.isEmpty ? nil : element.label
            let value = (element.value as? String)?.isEmpty == false ? element.value as? String : nil
            let identifier = element.identifier.isEmpty ? nil : element.identifier
            
            if label == nil && value == nil && identifier == nil && !element.isHittable {
                continue
            }
            
            let frame = element.frame
            let ref = "e\(refIndex)"
            
            let info: [String: Any] = [
                "ref": ref,
                "type": describeElementType(element.elementType),
                "label": label as Any,
                "value": value as Any,
                "identifier": identifier as Any,
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height,
                "isHittable": element.isHittable,
                "isEnabled": element.isEnabled
            ]
            
            elements.append(info)
            elementRefs[ref] = element
            refIndex += 1
        }
        
        return [
            "elements": elements,
            "count": elements.count,
            "bundleId": currentBundleId as Any
        ]
    }
    
    private func tapRef(ref: String) throws {
        guard let element = elementRefs[ref] else {
            throw NativeError.elementNotFound(ref)
        }
        
        guard element.exists && element.isHittable else {
            throw NativeError.elementNotHittable(ref)
        }
        
        element.tap()
    }
    
    private func find(text: String, action: String, value: String?) throws -> [String: Any] {
        guard let app = currentApp else {
            throw NativeError.noAppOpen
        }
        
        let predicate = NSPredicate(format: "label CONTAINS[cd] %@ OR value CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@", text, text, text)
        let matches = app.descendants(matching: .any).matching(predicate)
        
        guard matches.count > 0 else {
            return ["found": false]
        }
        
        // Find first hittable
        var targetElement: XCUIElement?
        for i in 0..<min(matches.count, 10) {
            let element = matches.element(boundBy: i)
            if element.exists && element.isHittable {
                targetElement = element
                break
            }
        }
        
        if targetElement == nil {
            targetElement = matches.element(boundBy: 0)
        }
        
        guard let element = targetElement, element.exists else {
            return ["found": false]
        }
        
        let ref = "f0"
        elementRefs[ref] = element
        
        let frame = element.frame
        let info: [String: Any] = [
            "ref": ref,
            "type": describeElementType(element.elementType),
            "label": element.label.isEmpty ? NSNull() : element.label,
            "value": (element.value as? String) ?? NSNull(),
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height,
            "isHittable": element.isHittable
        ]
        
        // Perform action
        switch action {
        case "tap":
            if element.isHittable {
                element.tap()
            }
        case "fill":
            if let fillValue = value {
                element.tap()
                element.typeText(fillValue)
            }
        default:
            break
        }
        
        return ["found": true, "ref": ref, "element": info, "action": action]
    }
    
    private func tap(x: Double, y: Double) throws {
        guard let app = currentApp else {
            throw NativeError.noAppOpen
        }
        
        let coordinate = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
        coordinate.tap()
    }
    
    private func swipe(direction: String) throws {
        guard let app = currentApp else {
            throw NativeError.noAppOpen
        }
        
        switch direction.lowercased() {
        case "up": app.swipeUp()
        case "down": app.swipeDown()
        case "left": app.swipeLeft()
        case "right": app.swipeRight()
        default:
            throw NativeError.invalidDirection(direction)
        }
    }
    
    private func screenshot() throws -> String {
        guard let app = currentApp else {
            throw NativeError.noAppOpen
        }
        
        let screenshot = app.screenshot()
        return screenshot.pngRepresentation.base64EncodedString()
    }
    
    // MARK: - Helpers
    
    private func describeElementType(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .staticText: return "staticText"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .textView: return "textView"
        case .image: return "image"
        case .icon: return "icon"
        case .link: return "link"
        case .searchField: return "searchField"
        case .scrollView: return "scrollView"
        case .table: return "table"
        case .cell: return "cell"
        case .collectionView: return "collectionView"
        case .switch: return "switch"
        case .slider: return "slider"
        case .navigationBar: return "navigationBar"
        case .tabBar: return "tabBar"
        case .toolbar: return "toolbar"
        case .alert: return "alert"
        case .sheet: return "sheet"
        case .window: return "window"
        case .application: return "application"
        case .other: return "other"
        default: return "unknown"
        }
    }
    
    // MARK: - HTTP Response Helpers
    
    private func sendJSON(_ connection: NWConnection, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            sendError(connection, message: "JSON encoding failed")
            return
        }
        
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(data.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        
        var fullResponse = Data(response.utf8)
        fullResponse.append(data)
        
        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendSuccess(_ connection: NWConnection, id: String, result: [String: Any]) {
        var response: [String: Any] = ["id": id, "success": true]
        response["result"] = result
        sendJSON(connection, json: response)
    }
    
    private func sendFailure(_ connection: NWConnection, id: String, error: String) {
        sendJSON(connection, json: ["id": id, "success": false, "error": error])
    }
    
    private func sendError(_ connection: NWConnection, message: String) {
        sendJSON(connection, json: ["error": message])
    }
}

// MARK: - Errors

enum NativeError: Error, LocalizedError {
    case missingParam(String)
    case unknownCommand(String)
    case noAppOpen
    case appLaunchFailed(String)
    case elementNotFound(String)
    case elementNotHittable(String)
    case invalidDirection(String)
    
    var errorDescription: String? {
        switch self {
        case .missingParam(let param):
            return "Missing required parameter: \(param)"
        case .unknownCommand(let cmd):
            return "Unknown command: \(cmd)"
        case .noAppOpen:
            return "No app is currently open. Call openApp first."
        case .appLaunchFailed(let bundleId):
            return "Failed to launch app: \(bundleId)"
        case .elementNotFound(let ref):
            return "Element not found: \(ref). Run snapshot first."
        case .elementNotHittable(let ref):
            return "Element not hittable: \(ref)"
        case .invalidDirection(let dir):
            return "Invalid swipe direction: \(dir)"
        }
    }
}
