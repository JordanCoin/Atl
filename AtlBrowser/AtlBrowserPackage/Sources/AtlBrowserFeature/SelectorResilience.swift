import Foundation

// MARK: - Selector Chain

/// A chain of selectors to try in order, with optional fallback script
struct SelectorChain: Codable {
    let chain: [String]
    let fallbackScript: String?
    let transform: String?

    init(chain: [String], fallbackScript: String? = nil, transform: String? = nil) {
        self.chain = chain
        self.fallbackScript = fallbackScript
        self.transform = transform
    }

    /// Create from a single selector string
    init(single: String) {
        self.chain = [single]
        self.fallbackScript = nil
        self.transform = nil
    }
}

// MARK: - Extraction Result

struct ExtractionResult {
    let value: Any?
    let selectorUsed: String
    let wasFallback: Bool
    let attempts: Int
    let success: Bool

    var description: String {
        if success {
            if wasFallback {
                return "Found via '\(selectorUsed)' (fallback, \(attempts) attempts)"
            } else {
                return "Found via '\(selectorUsed)'"
            }
        } else {
            return "Not found after \(attempts) attempts"
        }
    }
}

// MARK: - Run Status

enum RunStatus: String, Codable {
    case success   // All primary selectors worked
    case degraded  // Fallbacks used but data extracted
    case partial   // Some required extractions failed
    case failed    // Critical failure

    var emoji: String {
        switch self {
        case .success: return "✅"
        case .degraded: return "⚠️"
        case .partial: return "🟡"
        case .failed: return "❌"
        }
    }

    var isAcceptable: Bool {
        self == .success || self == .degraded
    }
}

// MARK: - Validation

struct ValidationRule: Codable {
    let type: ValidationType?
    let required: Bool?
    let minLength: Int?
    let maxLength: Int?
    let range: [Double]?
    let pattern: String?
    let notContains: [String]?
    let contains: [String]?

    enum ValidationType: String, Codable {
        case string
        case number
        case boolean
        case array
    }

    func validate(_ value: Any?) -> ValidationResult {
        // Check required
        if required == true && value == nil {
            return .failure("Value is required but missing")
        }

        guard let value = value else {
            return .success // Not required and nil is ok
        }

        // Type checking
        if let type = type {
            switch type {
            case .string:
                guard let str = value as? String else {
                    return .failure("Expected string, got \(Swift.type(of: value))")
                }
                return validateString(str)
            case .number:
                guard let num = asNumber(value) else {
                    return .failure("Expected number, got \(Swift.type(of: value))")
                }
                return validateNumber(num)
            case .boolean:
                guard value is Bool else {
                    return .failure("Expected boolean, got \(Swift.type(of: value))")
                }
            case .array:
                guard value is [Any] else {
                    return .failure("Expected array, got \(Swift.type(of: value))")
                }
            }
        }

        return .success
    }

    private func validateString(_ str: String) -> ValidationResult {
        if let min = minLength, str.count < min {
            return .failure("String too short: \(str.count) < \(min)")
        }
        if let max = maxLength, str.count > max {
            return .failure("String too long: \(str.count) > \(max)")
        }
        if let notContains = notContains {
            for forbidden in notContains {
                if str.lowercased().contains(forbidden.lowercased()) {
                    return .failure("String contains forbidden text: '\(forbidden)'")
                }
            }
        }
        if let contains = contains {
            for required in contains {
                if !str.contains(required) {
                    return .failure("String missing required text: '\(required)'")
                }
            }
        }
        if let pattern = pattern {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return .failure("Invalid regex pattern")
            }
            let range = NSRange(str.startIndex..., in: str)
            if regex.firstMatch(in: str, range: range) == nil {
                return .failure("String doesn't match pattern: \(pattern)")
            }
        }
        return .success
    }

    private func validateNumber(_ num: Double) -> ValidationResult {
        if let range = range, range.count >= 2 {
            if num < range[0] || num > range[1] {
                return .failure("Number \(num) outside range [\(range[0]), \(range[1])]")
            }
        }
        return .success
    }

    private func asNumber(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

enum ValidationResult {
    case success
    case failure(String)

    var isValid: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String? {
        if case .failure(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Retry Strategy

enum RetryStrategy: String, Codable {
    case scroll   // Scroll to middle of page
    case wait     // Extended wait (2s)
    case reload   // Full page reload
    case viewport // Change viewport size

    var description: String {
        switch self {
        case .scroll: return "Scrolling to reveal content"
        case .wait: return "Waiting for dynamic content"
        case .reload: return "Reloading page"
        case .viewport: return "Adjusting viewport"
        }
    }
}

// MARK: - Step Result

struct StepResult {
    let stepId: String
    let action: String
    let success: Bool
    let value: Any?
    let selectorUsed: String?
    let wasFallback: Bool
    let attempts: Int
    let validationResult: ValidationResult?
    let error: String?
    let duration: TimeInterval

    var statusEmoji: String {
        if success {
            return wasFallback ? "⚠️" : "✅"
        } else {
            return "❌"
        }
    }
}

// MARK: - Failure Artifacts

struct FailureArtifacts: Codable {
    let screenshot: Data?
    let fullPagePdf: Data?
    let domSnapshot: String?
    let failedSelector: String
    let triedSelectors: [String]
    let timestamp: Date
    let error: String

    func save(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: timestamp)

        if let screenshot = screenshot {
            try screenshot.write(to: directory.appendingPathComponent("failure-\(ts).png"))
        }
        if let pdf = fullPagePdf {
            try pdf.write(to: directory.appendingPathComponent("failure-\(ts).pdf"))
        }
        if let dom = domSnapshot {
            try dom.write(to: directory.appendingPathComponent("failure-\(ts).html"), atomically: true, encoding: .utf8)
        }

        let metadata: [String: Any] = [
            "failedSelector": failedSelector,
            "triedSelectors": triedSelectors,
            "timestamp": ts,
            "error": error
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataData.write(to: directory.appendingPathComponent("failure-\(ts).json"))
    }
}

// MARK: - Resilience Configuration

struct ResilienceConfig: Codable {
    let retryCount: Int
    let retryStrategies: [RetryStrategy]
    let captureOnFailure: Bool
    let degradedIsSuccess: Bool

    static let `default` = ResilienceConfig(
        retryCount: 2,
        retryStrategies: [.scroll, .wait],
        captureOnFailure: true,
        degradedIsSuccess: true
    )
}
