import UIKit
import WebKit

// MARK: - Touch Direction

enum SwipeDirection: String, Codable {
    case up, down, left, right
}

// MARK: - Touch Gesture Simulator

/// Simulates touch gestures on a WKWebView
/// Uses JavaScript touch event injection for reliable cross-content support
@MainActor
final class TouchGestureSimulator {
    
    private weak var webView: WKWebView?
    
    init(webView: WKWebView) {
        self.webView = webView
    }
    
    // MARK: - Tap
    
    /// Simulate a tap at the given coordinates
    func tap(at point: CGPoint) async throws {
        guard let webView = webView else { throw GestureError.webViewDeallocated }
        
        let js = """
        (function() {
            const x = \(point.x);
            const y = \(point.y);
            const element = document.elementFromPoint(x, y);
            if (!element) return { success: false, error: 'No element at point' };
            
            const touch = new Touch({
                identifier: Date.now(),
                target: element,
                clientX: x,
                clientY: y,
                pageX: x + window.scrollX,
                pageY: y + window.scrollY
            });
            
            const touchStart = new TouchEvent('touchstart', {
                bubbles: true,
                cancelable: true,
                touches: [touch],
                targetTouches: [touch],
                changedTouches: [touch]
            });
            
            const touchEnd = new TouchEvent('touchend', {
                bubbles: true,
                cancelable: true,
                touches: [],
                targetTouches: [],
                changedTouches: [touch]
            });
            
            element.dispatchEvent(touchStart);
            element.dispatchEvent(touchEnd);
            
            // Also dispatch click for elements that listen to click instead of touch
            const click = new MouseEvent('click', {
                bubbles: true,
                cancelable: true,
                clientX: x,
                clientY: y
            });
            element.dispatchEvent(click);
            
            return { success: true, element: element.tagName };
        })()
        """
        
        _ = try await webView.evaluateJavaScript(js)
    }
    
    // MARK: - Long Press
    
    /// Simulate a long press at the given coordinates
    func longPress(at point: CGPoint, duration: TimeInterval = 0.5) async throws {
        guard let webView = webView else { throw GestureError.webViewDeallocated }
        
        // Dispatch touchstart, wait in Swift, then dispatch touchend
        let touchStartJs = """
        (function() {
            const x = \(point.x);
            const y = \(point.y);
            const element = document.elementFromPoint(x, y);
            if (!element) return { success: false, error: 'No element at point' };
            
            window._longPressElement = element;
            window._longPressTouchId = Date.now();
            
            const touch = new Touch({
                identifier: window._longPressTouchId,
                target: element,
                clientX: x,
                clientY: y,
                pageX: x + window.scrollX,
                pageY: y + window.scrollY
            });
            
            element.dispatchEvent(new TouchEvent('touchstart', {
                bubbles: true,
                cancelable: true,
                touches: [touch],
                targetTouches: [touch],
                changedTouches: [touch]
            }));
            
            return { success: true, element: element.tagName };
        })()
        """
        
        _ = try await webView.evaluateJavaScript(touchStartJs)
        
        // Wait for the duration
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        
        // Dispatch touchend and contextmenu
        let touchEndJs = """
        (function() {
            const x = \(point.x);
            const y = \(point.y);
            const element = window._longPressElement || document.elementFromPoint(x, y);
            if (!element) return { success: false };
            
            const touch = new Touch({
                identifier: window._longPressTouchId || Date.now(),
                target: element,
                clientX: x,
                clientY: y,
                pageX: x + window.scrollX,
                pageY: y + window.scrollY
            });
            
            element.dispatchEvent(new TouchEvent('touchend', {
                bubbles: true,
                cancelable: true,
                touches: [],
                targetTouches: [],
                changedTouches: [touch]
            }));
            
            element.dispatchEvent(new MouseEvent('contextmenu', {
                bubbles: true,
                cancelable: true,
                clientX: x,
                clientY: y
            }));
            
            delete window._longPressElement;
            delete window._longPressTouchId;
            
            return { success: true };
        })()
        """
        
        _ = try await webView.evaluateJavaScript(touchEndJs)
    }
    
    // MARK: - Swipe
    
    /// Simulate a swipe gesture
    func swipe(direction: SwipeDirection, distance: CGFloat = 300, duration: TimeInterval = 0.3) async throws {
        guard let webView = webView else { throw GestureError.webViewDeallocated }
        
        let viewportSize = webView.bounds.size
        let centerX = viewportSize.width / 2
        let centerY = viewportSize.height / 2
        
        var startPoint: CGPoint
        var endPoint: CGPoint
        
        switch direction {
        case .up:
            startPoint = CGPoint(x: centerX, y: centerY + distance / 2)
            endPoint = CGPoint(x: centerX, y: centerY - distance / 2)
        case .down:
            startPoint = CGPoint(x: centerX, y: centerY - distance / 2)
            endPoint = CGPoint(x: centerX, y: centerY + distance / 2)
        case .left:
            startPoint = CGPoint(x: centerX + distance / 2, y: centerY)
            endPoint = CGPoint(x: centerX - distance / 2, y: centerY)
        case .right:
            startPoint = CGPoint(x: centerX - distance / 2, y: centerY)
            endPoint = CGPoint(x: centerX + distance / 2, y: centerY)
        }
        
        try await swipe(from: startPoint, to: endPoint, duration: duration)
    }
    
    /// Simulate a swipe between two points
    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval = 0.3) async throws {
        guard let webView = webView else { throw GestureError.webViewDeallocated }
        
        // Simplified swipe - dispatch touch events and scroll immediately
        // WKWebView doesn't handle async JS well, so we do it synchronously
        let js = """
        (function() {
            const startX = \(start.x);
            const startY = \(start.y);
            const endX = \(end.x);
            const endY = \(end.y);
            
            const element = document.elementFromPoint(startX, startY) || document.body;
            const touchId = Date.now();
            
            function createTouch(x, y) {
                return new Touch({
                    identifier: touchId,
                    target: element,
                    clientX: x,
                    clientY: y,
                    pageX: x + window.scrollX,
                    pageY: y + window.scrollY
                });
            }
            
            // Touch start
            const startTouch = createTouch(startX, startY);
            element.dispatchEvent(new TouchEvent('touchstart', {
                bubbles: true,
                cancelable: true,
                touches: [startTouch],
                targetTouches: [startTouch],
                changedTouches: [startTouch]
            }));
            
            // Touch move (single move to end position)
            const moveTouch = createTouch(endX, endY);
            element.dispatchEvent(new TouchEvent('touchmove', {
                bubbles: true,
                cancelable: true,
                touches: [moveTouch],
                targetTouches: [moveTouch],
                changedTouches: [moveTouch]
            }));
            
            // Touch end
            const endTouch = createTouch(endX, endY);
            element.dispatchEvent(new TouchEvent('touchend', {
                bubbles: true,
                cancelable: true,
                touches: [],
                targetTouches: [],
                changedTouches: [endTouch]
            }));
            
            // Trigger scroll
            const scrollX = startX - endX;
            const scrollY = startY - endY;
            window.scrollBy(scrollX, scrollY);
            
            return { success: true, scrolled: { x: scrollX, y: scrollY } };
        })()
        """
        
        _ = try await webView.evaluateJavaScript(js)
    }
    
    // MARK: - Pinch (Zoom)
    
    /// Simulate a pinch gesture (zoom in/out)
    func pinch(scale: CGFloat, duration: TimeInterval = 0.3) async throws {
        guard let webView = webView else { throw GestureError.webViewDeallocated }
        
        let viewportSize = webView.bounds.size
        let centerX = viewportSize.width / 2
        let centerY = viewportSize.height / 2
        
        // Initial finger distance
        let initialDistance: CGFloat = 100
        let finalDistance = initialDistance * scale
        
        // Simplified pinch - start, move to final, end (no animation)
        let js = """
        (function() {
            const centerX = \(centerX);
            const centerY = \(centerY);
            const initialDistance = \(initialDistance);
            const finalDistance = \(finalDistance);
            
            const element = document.elementFromPoint(centerX, centerY) || document.body;
            const touch1Id = Date.now();
            const touch2Id = Date.now() + 1;
            
            function createTouches(distance) {
                const halfDist = distance / 2;
                return [
                    new Touch({
                        identifier: touch1Id,
                        target: element,
                        clientX: centerX - halfDist,
                        clientY: centerY,
                        pageX: centerX - halfDist + window.scrollX,
                        pageY: centerY + window.scrollY
                    }),
                    new Touch({
                        identifier: touch2Id,
                        target: element,
                        clientX: centerX + halfDist,
                        clientY: centerY,
                        pageX: centerX + halfDist + window.scrollX,
                        pageY: centerY + window.scrollY
                    })
                ];
            }
            
            // Start
            const startTouches = createTouches(initialDistance);
            element.dispatchEvent(new TouchEvent('touchstart', {
                bubbles: true,
                cancelable: true,
                touches: startTouches,
                targetTouches: startTouches,
                changedTouches: startTouches
            }));
            
            // Move to final position
            const endTouches = createTouches(finalDistance);
            element.dispatchEvent(new TouchEvent('touchmove', {
                bubbles: true,
                cancelable: true,
                touches: endTouches,
                targetTouches: endTouches,
                changedTouches: endTouches
            }));
            
            // End
            element.dispatchEvent(new TouchEvent('touchend', {
                bubbles: true,
                cancelable: true,
                touches: [],
                targetTouches: [],
                changedTouches: endTouches
            }));
            
            return { success: true, scale: \(scale) };
        })()
        """
        
        _ = try await webView.evaluateJavaScript(js)
    }
}

// MARK: - Errors

enum GestureError: Error, LocalizedError {
    case webViewDeallocated
    case invalidCoordinates
    case gestureNotSupported(String)
    
    var errorDescription: String? {
        switch self {
        case .webViewDeallocated:
            return "WebView is no longer available"
        case .invalidCoordinates:
            return "Invalid touch coordinates"
        case .gestureNotSupported(let gesture):
            return "Gesture not supported: \(gesture)"
        }
    }
}
