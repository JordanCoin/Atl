import Foundation
import AppKit
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Detected UI Element

/// A UI element detected in a screenshot
public struct DetectedElement: Sendable {
    public let text: String
    public let bounds: CGRect  // Normalized 0-1 coordinates
    public let confidence: Float
}

// MARK: - Element Match Result (for Foundation Models)

@available(macOS 26, *)
@Generable
public struct ElementMatchResult {
    /// Index of the best matching element (-1 if none match)
    public var matchIndex: Int
    /// Confidence in the match (0.0 to 1.0)
    public var confidence: Double
    /// Reasoning for the match
    public var reasoning: String
}

// MARK: - Vision Service

/// Service for analyzing screenshots to find click targets
/// Uses Apple Vision framework for detection + Foundation Models for NLP matching
@MainActor
public class VisionService: ObservableObject {
    public static let shared = VisionService()

    @Published public var isProcessing = false
    @Published public var lastError: String?

    private init() {}

    /// Whether Foundation Models is available for NLP matching
    public var isAvailable: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    // MARK: - Find Click Target

    /// Analyze a screenshot and find where to click based on description
    public func findClickTarget(
        screenshot: Data,
        targetDescription: String
    ) async -> VisionClickResponse {
        isProcessing = true
        defer { isProcessing = false }

        // Step 1: Detect text elements using Vision framework
        guard let image = NSImage(data: screenshot),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return VisionClickResponse(
                found: false, x: 0, y: 0, confidence: 0,
                elementDescription: "", reasoning: "Failed to load screenshot"
            )
        }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        do {
            // Detect text elements
            let elements = try await detectTextElements(in: cgImage)

            if elements.isEmpty {
                return VisionClickResponse(
                    found: false, x: 0, y: 0, confidence: 0,
                    elementDescription: "", reasoning: "No text elements found in screenshot"
                )
            }

            // Step 2: Match description to detected elements
            let (matchedElement, confidence, reasoning) = await matchElementToDescription(
                elements: elements,
                description: targetDescription
            )

            if let element = matchedElement {
                // Convert normalized coordinates to pixel coordinates
                // Vision uses bottom-left origin, we need top-left
                let centerX = Int((element.bounds.midX) * CGFloat(imageWidth))
                let centerY = Int((1.0 - element.bounds.midY) * CGFloat(imageHeight))

                return VisionClickResponse(
                    found: true,
                    x: centerX,
                    y: centerY,
                    confidence: confidence,
                    elementDescription: element.text,
                    reasoning: reasoning
                )
            } else {
                return VisionClickResponse(
                    found: false, x: 0, y: 0, confidence: 0,
                    elementDescription: "",
                    reasoning: reasoning.isEmpty ? "No matching element found for: \(targetDescription)" : reasoning
                )
            }
        } catch {
            lastError = error.localizedDescription
            return VisionClickResponse(
                found: false, x: 0, y: 0, confidence: 0,
                elementDescription: "", reasoning: "Error: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Vision Framework Detection

    /// Detect text elements in the image using Apple Vision
    private func detectTextElements(in cgImage: CGImage) async throws -> [DetectedElement] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let elements = observations.compactMap { observation -> DetectedElement? in
                    guard let topCandidate = observation.topCandidates(1).first else {
                        return nil
                    }

                    return DetectedElement(
                        text: topCandidate.string,
                        bounds: observation.boundingBox,
                        confidence: topCandidate.confidence
                    )
                }

                continuation.resume(returning: elements)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Foundation Models NLP Matching

    /// Match a description to detected elements using Foundation Models or fallback
    private func matchElementToDescription(
        elements: [DetectedElement],
        description: String
    ) async -> (element: DetectedElement?, confidence: Double, reasoning: String) {
        // Build element list for matching
        let elementList = elements.enumerated().map { index, element in
            "[\(index)] \"\(element.text)\""
        }.joined(separator: "\n")

        // Try Foundation Models if available
        if #available(macOS 26, *) {
            do {
                let result = try await matchWithFoundationModels(
                    elements: elements,
                    elementList: elementList,
                    description: description
                )

                if result.matchIndex >= 0 && result.matchIndex < elements.count {
                    return (elements[result.matchIndex], result.confidence, result.reasoning)
                } else {
                    return (nil, 0, result.reasoning)
                }
            } catch {
                // Fall back to simple matching
                print("Foundation Models matching failed: \(error), using fallback")
            }
        }

        // Fallback: Simple string matching
        return simpleMatch(elements: elements, description: description)
    }

    @available(macOS 26, *)
    private func matchWithFoundationModels(
        elements: [DetectedElement],
        elementList: String,
        description: String
    ) async throws -> ElementMatchResult {
        let session = LanguageModelSession()

        let prompt = """
        You are helping find a UI element to click based on a user's description.

        USER WANTS TO CLICK: "\(description)"

        DETECTED TEXT ELEMENTS:
        \(elementList)

        Which element best matches what the user wants to click?
        - Return the index number of the best match
        - If no element matches, return -1
        - Consider partial matches, synonyms, and context
        """

        let response = try await session.respond(to: prompt, generating: ElementMatchResult.self)
        return response.content
    }

    /// Simple string matching fallback
    private func simpleMatch(
        elements: [DetectedElement],
        description: String
    ) -> (element: DetectedElement?, confidence: Double, reasoning: String) {
        let searchTerms = description.lowercased().components(separatedBy: .whitespaces)

        // Try exact match first
        if let exactMatch = elements.first(where: {
            $0.text.lowercased() == description.lowercased()
        }) {
            return (exactMatch, 1.0, "Exact match found")
        }

        // Try contains match
        if let containsMatch = elements.first(where: {
            $0.text.lowercased().contains(description.lowercased())
        }) {
            return (containsMatch, 0.8, "Text contains search term")
        }

        // Try partial word match
        for element in elements {
            let elementWords = element.text.lowercased().components(separatedBy: .whitespaces)
            let matchCount = searchTerms.filter { term in
                elementWords.contains { word in
                    word.contains(term) || term.contains(word)
                }
            }.count

            if matchCount > 0 {
                let confidence = Double(matchCount) / Double(searchTerms.count) * 0.7
                return (element, confidence, "Partial word match")
            }
        }

        return (nil, 0, "No matching element found using simple text matching")
    }

    // MARK: - Screenshot Capture

    /// Capture screenshot of simulator using simctl
    public func captureSimulatorScreenshot(udid: String) async -> Data? {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim_screenshot_\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", tempPath.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0,
               let data = try? Data(contentsOf: tempPath) {
                try? FileManager.default.removeItem(at: tempPath)
                return data
            }
        } catch {
            print("simctl screenshot failed: \(error)")
        }

        return nil
    }
}

// MARK: - Vision Errors

enum VisionError: LocalizedError {
    case invalidScreenshot
    case notAvailable
    case generationFailed(String)
    case noElementsDetected

    var errorDescription: String? {
        switch self {
        case .invalidScreenshot:
            return "Invalid screenshot data"
        case .notAvailable:
            return "Foundation Models not available"
        case .generationFailed(let message):
            return "Vision analysis failed: \(message)"
        case .noElementsDetected:
            return "No UI elements detected in screenshot"
        }
    }
}
