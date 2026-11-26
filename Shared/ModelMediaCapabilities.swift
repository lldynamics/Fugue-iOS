import Foundation

enum ModelMediaFeature: String, CaseIterable {
    case imageInput, imageOutput, audioInput, audioOutput, videoInput, videoOutput

    var title: String {
        switch self {
        case .imageInput: return String(localized: "图像输入")
        case .imageOutput: return String(localized: "图像输出")
        case .audioInput: return String(localized: "语音输入")
        case .audioOutput: return String(localized: "语音输出")
        case .videoInput: return String(localized: "视频输入")
        case .videoOutput: return String(localized: "视频输出")
        }
    }
}

/// Missing entries mean the provider hasn't supplied a value for that direction.
struct ModelMediaCapabilities: Codable, Hashable {
    private var values: [String: Bool] = [:]

    subscript(_ feature: ModelMediaFeature) -> Bool? {
        get { values[feature.rawValue] }
        set { values[feature.rawValue] = newValue }
    }

    var hasInformation: Bool { !values.isEmpty }

    init(inputs: [String]? = nil, outputs: [String]? = nil) {
        if let input = Self.normalized(inputs) {
            self[.imageInput] = input.contains("image")
            self[.audioInput] = input.contains("audio")
            self[.videoInput] = input.contains("video")
        }
        if let output = Self.normalized(outputs) {
            self[.imageOutput] = output.contains("image")
            self[.audioOutput] = output.contains("audio")
            self[.videoOutput] = output.contains("video")
        }
    }

    static func normalized(_ values: [String]?) -> Set<String>? {
        guard let values else { return nil }
        let result = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        return result.isEmpty ? nil : result
    }

    /// Exact public IDs checked against developers.openai.com/api/docs/models/<id>.md.
    /// Unknown models and third-party deployments do not inherit a similarly named model's capabilities.
    static func documentedOpenAI(_ id: String) -> Self? {
        switch id {
        case "gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6-luna", "gpt-5.4", "gpt-5.4-mini",
             "gpt-5", "gpt-5-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini":
            return Self(inputs: ["text", "image"], outputs: ["text"])
        case "gpt-audio", "gpt-audio-mini", "gpt-4o-audio-preview", "gpt-4o-mini-audio-preview":
            return Self(inputs: ["text", "audio"], outputs: ["text", "audio"])
        case "gpt-image-1", "gpt-image-2":
            return Self(inputs: ["text", "image"], outputs: ["image"])
        case "gpt-4o-transcribe", "whisper-1":
            return Self(inputs: ["audio"], outputs: ["text"])
        case "tts-1", "gpt-4o-mini-tts":
            return Self(inputs: ["text"], outputs: ["audio"])
        default: return nil
        }
    }
}

extension ModelSpec {
    func mediaCapabilities(baseURL: String) -> ModelMediaCapabilities {
        var capabilities = reportedMedia ?? ModelMediaCapabilities()
        if URLComponents(string: baseURL)?.host?.lowercased() == "api.openai.com",
           let documented = ModelMediaCapabilities.documentedOpenAI(id) {
            for feature in ModelMediaFeature.allCases where capabilities[feature] == nil {
                capabilities[feature] = documented[feature]
            }
        }
        return capabilities
    }
}
