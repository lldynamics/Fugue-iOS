import XCTest
import PDFKit
import SwiftData
import Vision
@testable import iOSBox

final class ModelWorkbenchTests: XCTestCase {
    @MainActor func testTimeoutPreservesConfirmedCapabilityAndLegacyUnknownStaysUnknown() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let db = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let spec = ModelSpec(id: "pdf-retry")
        let provider = ProviderConfig(name: "Retry", protocolType: .openAICompatible, baseURL: "http://127.0.0.1/v1", models: [spec])
        db.mainContext.insert(provider)
        let accepted = AppCompliance.hasAcceptedAIDisclosure()
        AppCompliance.setAcceptedAIDisclosure(true)
        defer { AppCompliance.setAcceptedAIDisclosure(accepted) }
        let model = TaskModel(provider: provider, spec: spec) { _ in
            AsyncThrowingStream { $0.finish(throwing: URLError(.timedOut)) }
        }
        let probe = CapabilityProbe.pdf, key = probe.key(model)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        struct Old: Encodable { let passed: Bool; let date: Date; let detail: String }
        let yesterday = Date(timeIntervalSinceNow: -86400)
        UserDefaults.standard.set(try JSONEncoder().encode(Old(passed: true, date: yesterday, detail: "通过")), forKey: key)
        do { try await probe.test(model); XCTFail("expected a timeout") } catch {}
        let result = try XCTUnwrap(probe.result(model))
        XCTAssertEqual(result.passed, true)
        XCTAssertEqual(result.confirmedAt, yesterday)
        XCTAssertEqual(result.detail, "timeout")
        let ranked = ModelRecommendation.rank(providers: [provider], recent: [], requirement: probe.rawValue,
                                              preference: "速度优先", currency: "USD", budget: "", estimate: 10)
        XCTAssertEqual(ranked.map(\.model.id), [model.id])
        UserDefaults.standard.set(try JSONEncoder().encode(Old(passed: false, date: yesterday, detail: "请求失败，能力未知")), forKey: key)
        XCTAssertNil(probe.result(model)?.passed)
    }

    @MainActor func testClaimRecordsFollowRevisionAfterReloadAndRejectLateResults() throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let db = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = db.mainContext
        let reply = ChatMessage(role: .assistant, content: "The allowed time is seven days.")
        let chat = Conversation(title: "Verification")
        context.insert(chat); context.insert(reply); reply.conversation = chat
        let old = ClaimCheckRecord.Version(reply)
        let report = ClaimCheckRecord(checkedText: "seven days", model: "Verifier", statements: [.init(text: "seven days", verdict: "材料不足", quote: nil, citation: nil)])
        try report.save(to: reply, version: old)
        reply.assistanceMetadata.revisions = [ChatEngine.snapshotRevision(of: reply)]
        reply.assistanceMetadata.claimChecks = nil
        reply.content = "The allowed time is ten days."
        XCTAssertThrowsError(try report.save(to: reply, version: old))
        ChatEngine.shared.selectRevision(index: 0, for: reply, context: context)
        XCTAssertEqual(reply.assistanceMetadata.claimChecks, [report])
        let another = ClaimCheckRecord(checkedText: "time", model: "Verifier", statements: report.statements)
        try another.save(to: reply, version: .init(reply))
        ChatEngine.shared.selectRevision(index: 1, for: reply, context: context)
        XCTAssertNil(reply.assistanceMetadata.claimChecks)
        let reopened = try XCTUnwrap(ModelContext(db).fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertEqual(reopened.assistanceMetadata.revisions.first?.claimChecks, [another, report])
        let backup = BackupService.snapshot(chat, forExport: true)
        XCTAssertEqual(backup.messages.first?.assistanceMetadata?.revisions.first?.claimChecks, [another, report])
    }
    @MainActor func testRealProbeFixturesAndAccountScopedResults() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let db = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let spec = ModelSpec(id: "same-model")
        let provider = ProviderConfig(name: "Probe", protocolType: .openAICompatible, baseURL: "http://127.0.0.1/v1", models: [spec])
        db.mainContext.insert(provider)
        let accepted = AppCompliance.hasAcceptedAIDisclosure()
        AppCompliance.setAcceptedAIDisclosure(true)
        defer { AppCompliance.setAcceptedAIDisclosure(accepted) }
        let model = TaskModel(provider: provider, spec: spec) { request in
            AsyncThrowingStream { stream in
                let input = request.messages[0]
                do {
                    if let file = input.attachments.first, let data = Data(base64Encoded: file.dataBase64 ?? "") {
                        XCTAssertNil(file.extractedText)
                        if file.kind == .document {
                            XCTAssertTrue(file.hasRequestedPDFFile)
                            let digits = PDFDocument(data: data)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            stream.yield(.contentDelta(digits))
                        } else {
                            let recognition = VNRecognizeTextRequest()
                            recognition.recognitionLevel = .accurate
                            recognition.recognitionLanguages = ["en-US"]
                            try VNImageRequestHandler(data: data).perform([recognition])
                            stream.yield(.contentDelta(recognition.results?.first?.topCandidates(1).first?.string ?? ""))
                        }
                    } else {
                        let code = String(input.content.filter(\.isNumber))
                        let json = "{\"code\":\"\(code)\"}"
                        if request.tools.isEmpty {
                            XCTAssertNotNil(request.schemaObject)
                            stream.yield(.contentDelta(json))
                        } else {
                            stream.yield(.toolCall(.init(id: "test", name: "record_code", argumentsJSON: json)))
                        }
                    }
                    stream.yield(.usage(promptTokens: 7, completionTokens: 2)); stream.finish()
                } catch { stream.finish(throwing: error) }
            }
        }
        let other = TaskModel(provider: ProviderConfig(name: "Other", protocolType: .openAICompatible, baseURL: provider.baseURL, models: [spec]), spec: spec)
        defer { for probe in CapabilityProbe.allCases { UserDefaults.standard.removeObject(forKey: probe.key(model)) } }
        for probe in CapabilityProbe.allCases {
            try await probe.test(model)
            XCTAssertEqual(probe.result(model)?.passed, true, probe.rawValue)
            XCTAssertNil(probe.result(other))
        }
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<RequestRecord>()), 4)
        provider.baseURL = "http://127.0.0.2/v1"
        do {
            _ = try await model.run("", input: "changed")
            XCTFail("An endpoint changed after selection")
        } catch LLMError.unavailableModel { }
    }

    func testSchemaNegotiatedOnAllProtocolsAndDisabledForEverydayChats() throws {
        var req = LLMClient.buildPingRequest(providerName: "Sandbox", protocolType: .gemini, baseURL: "https://example.test", apiKey: "", customHeaders: [], modelID: "test")
        XCTAssertNil(OpenAICompatibleAdapter.buildRequestBody(req)["response_format"])
        req.outputSchema = #"{"type":"object","properties":{"code":{"type":"string"}},"required":["code"],"additionalProperties":false}"#
        let chat = OpenAICompatibleAdapter.buildRequestBody(req)["response_format"] as? [String: Any]
        XCTAssertEqual(chat?["type"] as? String, "json_schema")
        let responses = OpenAIResponsesAdapter.buildRequestBody(req)["text"] as? [String: Any]
        XCTAssertEqual((responses?["format"] as? [String: Any])?["name"] as? String, "result")
        let claude = AnthropicAdapter.buildRequestBody(req)["output_config"] as? [String: Any]
        XCTAssertNotNil(claude?["format"])
        req.wantsImage = true
        let gemini = GeminiAdapter.buildRequestBody(req)["generationConfig"] as? [String: Any]
        XCTAssertNotNil(gemini?["responseJsonSchema"])
        XCTAssertEqual(gemini?["responseModalities"] as? [String], ["TEXT","IMAGE"])
    }

    @MainActor func testResponsesImageEditHandlesStreamAndJSONWithoutDuplicateVersions() throws {
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let data = UIGraphicsImageRenderer(bounds: bounds).pngData { ctx in
            UIColor.blue.setFill(); ctx.fill(bounds)
        }
        let item: [String: Any] = ["type": "image_generation_call", "id": "img-1", "result": data.base64EncodedString()]
        let response = ["output": [item]]
        var state = OpenAIResponsesAdapter.StreamParserState()
        func countImages(_ events: [LLMStreamEvent]) -> Int {
            events.filter { if case .attachmentDelta = $0 { return true }; return false }.count
        }
        let stream = try OpenAIResponsesAdapter.parseSSEEventObject(["type": "response.output_item.done", "item": item], state: &state)
        XCTAssertEqual(countImages(stream), 1)
        let complete: [String: Any] = ["type": "response.completed", "response": response]
        XCTAssertEqual(countImages(try OpenAIResponsesAdapter.parseSSEEventObject(complete, state: &state)), 0)
        var fresh = OpenAIResponsesAdapter.StreamParserState()
        XCTAssertEqual(countImages(try OpenAIResponsesAdapter.parseSSEEventObject(complete, state: &fresh)), 1)
        XCTAssertEqual(countImages(try OpenAIResponsesAdapter.parseNonStreamingResponse(JSONSerialization.data(withJSONObject: response))), 1)
    }

    func testHybridRetrievalFindsParaphraseAndHonorsReadingLimit() async throws {
        let id = UUID()
        let book = BookManuscript(title: "采购手册", chapters: [
            .init(title: "付款", text: "应在通过验收之后付款。"),
            .init(title: "交付", text: "逾期交付应告知买方。")
        ])
        let docs = [KnowledgeDocumentSnapshot(id: id, title: book.title, manuscript: try book.encoded())]
        let index = ProjectKnowledgeSearch()
        let full = try await index.retrieve(from: docs, query: "晚交货怎么办", semantic: true)
        XCTAssertTrue(full.passages.contains { $0.excerpt.contains("逾期交付") && $0.chapterIndex == 1 && $0.utf16Offset != nil })
        let limited = try await index.retrieve(from: docs, query: "晚交货怎么办", chapterLimits: [id:0], semantic: true)
        XCTAssertFalse(limited.passages.contains { $0.chapterIndex == 1 })
    }

    @MainActor func testEvidenceRejectsFabricatedQuoteAndInvalidReferenceNumbers() {
        let source = ReadingCitation(KnowledgePassage(id: 1, volumeID: UUID(), documentTitle: "合同", sectionTitle: "交付", excerpt: "7个工作日内答复。"))
        func check(_ n: Int, _ text: String) -> ReadingCitation? {
            ClaimCheckSheet.Finding(claim: "期限", verdict: "原文支持", source: n, quote: text).citation(in: [source])
        }
        XCTAssertNotNil(check(1, "7个工作日"))
        XCTAssertNil(check(1, "7个自然日"))
        XCTAssertNil(check(Int.min, "7个工作日"))
        XCTAssertNil(check(2, "7个工作日"))
    }

    @MainActor func testCSVPreservesBlanksQuotesAndNeutralizesFormulas() {
        let cells = [ModelWorkshop.ExtractCell(value: "a,\"b\"", column: "名称", row: 1, source: nil),
                     .init(value: "=A1", column: "价格", row: 1, source: nil),
                     .init(value: "", column: "名称", row: 2, source: nil),
                     .init(value: "12", column: "价格", row: 2, source: nil)]
        XCTAssertEqual(ModelWorkshop.csv(cells), "\u{feff}\"名称\",\"价格\"\r\n\"a,\"\"b\"\"\",\"'=A1\"\r\n\"\",\"12\"")
    }

    func testReviewCanAcceptOrRejectEachEditIndependently() {
        let old = "保留\n删除\n相同\n旧版本\n尾行", new = "保留\n相同\n替换\n尾行\n新增"
        let patch = DraftRevision(original: old, revision: new)
        let changed = patch.changes.filter(\.changed)
        XCTAssertEqual(changed.count, 3)
        XCTAssertEqual(patch.text(accepting: []), old)
        XCTAssertEqual(patch.text(accepting: Set(changed.map(\.id))), new)
        XCTAssertEqual(patch.text(accepting: [changed[1].id]), "保留\n删除\n相同\n替换\n尾行")
    }

    @MainActor func testLiveTranscriptsAppendDeltasAndKeepInterruptedTurnsSeparate() {
        let voice = LiveVoiceSession()
        voice.receive(["inputTranscription": ["text": "你好"]])
        voice.receive(["outputTranscription": ["text": "请"]])
        voice.receive(["outputTranscription": ["text": "说"]])
        voice.receive(["interrupted": true])
        voice.receive(["inputTranscription": ["text": "等等"]])
        XCTAssertEqual(voice.lines.map(\.text), ["你好", "请说", "等等"])
        XCTAssertEqual(voice.lines.map(\.role), [.user, .assistant, .user])
    }

    @MainActor func testCompositingOnlyReplacesSelectedPixels() throws {
        let size = CGSize(width: 8, height: 8)
        func solid(_ color: UIColor) -> UIImage {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
                color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            }
        }
        let data = RegionImageEditor.replacingRegion(in: solid(.red), size: size, rect: CGRect(x: 2, y: 2, width: 4, height: 4), with: solid(.blue))
        let cg = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var bytes = [UInt8](repeating: 0, count: 256)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        }
        XCTAssertEqual(Array(bytes[0..<4]), [255,0,0,255])
        XCTAssertEqual(Array(bytes[108..<112]), [0,0,255,255])
    }

    func testImageEditBranchKeepsOriginalPayloadAndParent() throws {
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"image","fileName":"original","mimeType":"image/png","dataBase64":"YQ==","byteSize":1}"#
        var attachment = try JSONDecoder().decode(MessageAttachment.self, from: Data(old.utf8))
        let parent = EditedImage(parent: nil, instruction: "天空", png: Data([2]))
        attachment.editedVersions = [parent, .init(parent: parent.id, instruction: "云", png: Data([3]))]
        let restored = try JSONDecoder().decode(MessageAttachment.self, from: JSONEncoder().encode(attachment))
        XCTAssertEqual(restored.dataBase64, "YQ==")
        XCTAssertEqual(restored.editedVersions?.last?.parent, parent.id)
        XCTAssertEqual(restored.editedVersions, attachment.editedVersions)
    }
}
