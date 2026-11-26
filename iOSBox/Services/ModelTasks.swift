import CryptoKit
import SwiftData
import UIKit

enum ModelTaskError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

struct ModelTaskOutput {
    var cost = "费用未知"
    var text = ""
    var calls: [LLMToolCall] = []
    var images: [MessageAttachment] = []
}

enum ModelTaskJSON {
    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines)
        if let first = lines.first, ["```", "```json"].contains(first.lowercased()), lines.last == "```", lines.count >= 3 {
            text = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    static let tableSchema = #"""
    {"type":"object","properties":{"rows":{"type":"array","items":{"type":"array","items":{"type":"object","properties":{"column":{"type":"string"},"value":{"type":"string"},"source":{"type":["integer","null"]},"quote":{"type":["string","null"]}},"required":["column","value","source","quote"],"additionalProperties":false}}}},"required":["rows"],"additionalProperties":false}
    """#
}

@MainActor
struct TaskModel: Identifiable {
    let provider: ProviderConfig
    let spec: ModelSpec
    let id: String
    let recipientCheck: @MainActor @Sendable () throws -> Void
    typealias Stream = (LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    private let stream: Stream
    init(provider: ProviderConfig, spec: ModelSpec, stream: @escaping Stream = { LLMClient.streamChat($0) }) {
        self.stream = stream
        self.provider = provider
        self.spec = spec
        self.id = provider.id.uuidString + "/" + spec.id
        recipientCheck = provider.transmissionCheck(for: spec.id)
    }
    var recipient: String { AppCompliance.recipient(provider: provider.name, model: spec.id, baseURL: provider.baseURL) }
    var fingerprint: String {
        SHA256.hash(data: Data([provider.credentialID.uuidString, provider.baseURL, provider.protocolRaw, spec.id].joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func run(_ instruction: String, input: String, attachments: [MessageAttachment] = [],
             tools: [LLMToolDefinition] = [], schema: String? = nil, image: Bool = false,
             limit: Int = 2048, conversationID: UUID = UUID(), kind: RequestKind = .modelTask) async throws -> ModelTaskOutput {
        let check = recipientCheck
        try check()
        try AppCompliance.requireConsent()
        guard let context = provider.modelContext else { throw LLMError.unavailableModel }
        var request = LLMChatRequest(providerName: provider.name, protocolType: provider.protocolType,
            baseURL: provider.baseURL, apiKey: provider.apiKey, apiKeys: provider.extraAPIKeys,
            customHeaders: provider.resolvedCustomHeaders, modelID: spec.id, supportsReasoning: spec.supportsReasoning,
            systemPrompt: instruction, messages: [.init(role: .user, content: input, attachments: attachments)],
            temperature: nil, topP: 1, maxOutputTokens: limit, enableThinking: false, thinkingBudgetTokens: 0,
            idleTimeoutSeconds: provider.customIdleTimeout, tools: tools)
        request.outputSchema = schema
        request.wantsImage = image
        request.validateBeforeSending = check
        var record = RequestRecord(target: provider.makeTarget(for: spec), spec: spec, conversationID: conversationID, messageID: UUID(), kind: kind)
        context.insert(record)
        try context.save()
        var start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        do {
            var output = ModelTaskOutput()
            for try await event in stream(request) {
                try Task.checkCancellation()
                if case .retrying(let status) = event {
                    record = record.startRetry(after: status, elapsedMs: elapsed(), target: provider.makeTarget(for: spec), spec: spec, in: context)
                    start = Date()
                    continue
                }
                record.observe(event, elapsedMs: elapsed())
                switch event {
                case .contentDelta(let text): output.text += text
                case .toolCall(let call): output.calls.append(call)
                case .attachmentDelta(let attachment): output.images.append(attachment)
                case .finished(let reason): throw ModelTaskError.invalid(reason.rawValue)
                default: break
                }
            }
            try Task.checkCancellation()
            guard !output.text.isEmpty || !output.calls.isEmpty || !output.images.isEmpty else { throw LLMError.emptyResponse }
            record.finish(.succeeded, elapsedMs: elapsed())
            try context.save()
            if let cost = record.estimatedCost, let currency = record.currency { output.cost = RequestLedger.costText(cost, currency: currency) }
            return output
        } catch {
            record.finish(Task.isCancelled ? .cancelled : .failed, elapsedMs: elapsed())
            try context.save()
            throw error
        }
    }
}

enum CapabilityProbe: String, CaseIterable, Identifiable {
    case image = "图片读字", pdf = "原生 PDF", tool = "工具调用", json = "结构化输出"
    var id: Self { self }
    var title: String {
        switch self {
        case .image: String(localized: "图片读字")
        case .pdf: String(localized: "原生 PDF")
        case .tool: String(localized: "工具调用")
        case .json: String(localized: "结构化输出")
        }
    }
    struct Result: Codable {
        let passed: Bool?
        let date: Date
        let detail: String
        var confirmedAt: Date?

        var isInconclusive: Bool { detail != "通过" && detail != "返回值未通过校验" }

        var summary: String {
            guard isInconclusive else { return passed == true ? String(localized: "通过") : String(localized: "返回值未通过校验") }
            let latest: String
            switch detail {
            case "timeout": latest = String(localized: "本次超时")
            case "rateLimit": latest = String(localized: "本次被限流")
            default: latest = String(localized: "本次请求失败")
            }
            guard let passed, let confirmedAt else { return String(localized: "能力待确认") + " · " + latest }
            let previous = passed ? String(localized: "上次通过") : String(localized: "上次未通过校验")
            return previous + " " + confirmedAt.formatted(date: .abbreviated, time: .omitted) + " · " + latest
        }
    }

    @MainActor func key(_ model: TaskModel) -> String { "model.probe." + model.fingerprint + rawValue }
    @MainActor func result(_ model: TaskModel) -> Result? {
        guard let data = UserDefaults.standard.data(forKey: key(model)),
              var result = try? JSONDecoder().decode(Result.self, from: data) else { return nil }
        // Earlier versions persisted a transport error as a negative capability test.
        if result.detail == "请求失败，能力未知" { return Result(passed: nil, date: result.date, detail: "error") }
        if !result.isInconclusive && result.confirmedAt == nil { result.confirmedAt = result.date }
        return result
    }

    @MainActor func test(_ model: TaskModel) async throws {
        let code = String(Int.random(in: 100000...999999))
        let value: String
        let storageKey = key(model)
        do {
            switch self {
            case .image, .pdf:
                let bounds = CGRect(x: 0, y: 0, width: 300, height: 100)
                func draw() {
                    UIColor.white.setFill()
                    UIRectFill(bounds)
                    (code as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black])
                }
                let data: Data
                if self == .pdf {
                    data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in ctx.beginPage(); draw() }
                } else {
                    data = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in draw() }
                }
                let attachment = MessageAttachment(kind: self == .pdf ? .document : .image, fileName: self == .pdf ? "sample.pdf" : "sample.png", mimeType: self == .pdf ? "application/pdf" : "image/png", dataBase64: data.base64EncodedString(), extractedText: nil, byteSize: data.count, sendOriginalPDF: self == .pdf)
                value = try await model.run("", input: "Return only the digits printed in the attachment.", attachments: [attachment]).text
            case .tool:
                let definition = LLMToolDefinition(name: "record_code", description: "Record a code", parametersSchemaJSON: #"{"type":"object","properties":{"code":{"type":"string"}},"required":["code"]}"#)
                let output = try await model.run("", input: "Call record_code with code \(code).", tools: [definition])
                value = output.calls.first(where: { $0.name == definition.name })?.argumentsDictionary["code"] as? String ?? ""
            case .json:
                let schema = #"{"type":"object","properties":{"code":{"type":"string"}},"required":["code"],"additionalProperties":false}"#
                let output = try await model.run("", input: "Return code \(code) using the configured output format.", schema: schema)
                value = (try? JSONDecoder().decode([String: String].self, from: Data(output.text.utf8)))?["code"] ?? ""
            }
            let pass = value.trimmingCharacters(in: .whitespacesAndNewlines) == code
            let now = Date()
            try Task.checkCancellation()
            UserDefaults.standard.set(try JSONEncoder().encode(Result(passed: pass, date: now, detail: pass ? "通过" : "返回值未通过校验", confirmedAt: now)), forKey: storageKey)
        } catch {
            if !Task.isCancelled {
                let previous = result(model)
                let detail: String
                switch error {
                case let error as URLError where error.code == .timedOut: detail = "timeout"
                case LLMError.httpError(408, _), LLMError.httpError(504, _): detail = "timeout"
                case LLMError.httpError(429, _): detail = "rateLimit"
                default: detail = "error"
                }
                let attempt = Result(passed: previous?.passed, date: Date(), detail: detail, confirmedAt: previous?.confirmedAt)
                UserDefaults.standard.set(try JSONEncoder().encode(attempt), forKey: storageKey)
            }
            throw error
        }
    }
}
