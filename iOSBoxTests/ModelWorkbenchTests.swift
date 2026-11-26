import XCTest
import PDFKit
import SwiftData
import Vision
@testable import iOSBox

final class ModelWorkbenchTests: XCTestCase {
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
