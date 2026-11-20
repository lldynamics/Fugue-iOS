import XCTest
import SwiftData
@testable import iOSBox

private final class PhaseThreeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LLMChatRequest] = []
    private var queries: [String] = []
    func append(_ value: LLMChatRequest) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func append(query: String) { lock.lock(); defer { lock.unlock() }; queries.append(query) }
    var requests: [LLMChatRequest] { lock.lock(); defer { lock.unlock() }; return values }
    var searchQueries: [String] { lock.lock(); defer { lock.unlock() }; return queries }
}

private final class SearchFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            copy.httpBody = body
        }
        Self.lock.lock(); Self.captured.append(copy); Self.lock.unlock()
        let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let body = key == "Bearer large" ? String(repeating: "x", count: TavilySearchClient.maximumBytes + 1)
            : #"{"results":[{"title":"Source","url":"https://example.com/a","content":"Evidence."}],"usage":{"credits":1}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: key == "Bearer failure" ? 429 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Length": String(body.utf8.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class PhaseThreeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }
    override func tearDown() async throws { context = nil; container = nil }

    private func provider(_ name: String, vision: Bool = false, enabled: Bool = true) -> ProviderConfig {
        var spec = ModelSpec(id: name, supportsVision: vision)
        spec.inputPricePerMillion = 2; spec.outputPricePerMillion = 8; spec.priceCurrency = "USD"
        let p = ProviderConfig(name: name, protocolType: .openAICompatible, baseURL: "http://localhost:18801/v1",
                               isEnabled: enabled, models: [spec])
        context.insert(p)
        return p
    }
    private func target(_ p: ProviderConfig) -> ResolvedModelTarget { p.makeTarget(for: p.models[0]) }
    private func conversation(_ primary: ProviderConfig, backups: [ProviderConfig] = []) -> Conversation {
        let c = Conversation(primaryTarget: target(primary))
        c.assistanceSettings.fallbackEnabled = !backups.isEmpty
        c.assistanceSettings.fallbackTargets = backups.map(target)
        context.insert(c)
        return c
    }
    private func wait(_ engine: ChatEngine, _ c: Conversation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while engine.isGenerating(in: c.id), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(engine.isGenerating(in: c.id))
    }
    nonisolated private static func success(_ answer: String = "Answer") -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(.contentDelta(answer)); c.yield(.usage(promptTokens: 10, completionTokens: 20)); c.yield(.done); c.finish()
        }
    }
    nonisolated private static func evidence(_ query: String) -> SearchEvidence {
        SearchEvidence(query: query, searchedAt: Date(), sources: [SearchSource(id: 1, title: "Reference", url: URL(string: "https://example.com/source")!, snippet: "Untrusted snippet")], credits: 1)
    }

    func testMemoryIsExplicitSharedAcrossModelsAndCanBeOmittedPerSend() async throws {
        let a = provider("a"), b = provider("b"), c = conversation(a)
        context.insert(PersonalMemory(content: "MY_SWIFT_PREFERENCE"))
        context.insert(PersonalMemory(content: "DISABLED_FACT", isEnabled: false))
        let capture = PhaseThreeCapture()
        let engine = ChatEngine { r in capture.append(r); return Self.success() }
        _ = engine.sendUserMessage(text: "first", attachments: [], in: c, providers: [a,b], context: context)
        try await wait(engine,c)
        XCTAssertFalse(capture.requests[0].systemPrompt.contains("MY_SWIFT_PREFERENCE"))
        c.assistanceSettings.usePersonalMemory = true
        for p in [a,b] {
            c.primaryTarget = target(p)
            _ = engine.sendUserMessage(text: "next", attachments: [], in: c, providers: [a,b], context: context)
            try await wait(engine,c)
        }
        XCTAssertTrue(capture.requests[1...2].allSatisfy { $0.systemPrompt.contains("MY_SWIFT_PREFERENCE") && !$0.systemPrompt.contains("DISABLED_FACT") })
        _ = engine.sendUserMessage(text: "private turn", attachments: [], in: c, providers: [a,b], context: context, options: GenerationOptions(omitMemory: true))
        try await wait(engine,c)
        XCTAssertFalse(capture.requests.last!.systemPrompt.contains("MY_SWIFT_PREFERENCE"))
        XCTAssertTrue(c.assistanceSettings.usePersonalMemory)
        XCTAssertTrue(c.sortedMessages.last!.assistanceMetadata.omittedMemory)
        XCTAssertFalse(capture.requests.last!.messages.map(\.content).joined().contains("MY_SWIFT_PREFERENCE"))
    }

    func testEditingDisablingAndDeletingMemoryChangesNextPrompt() throws {
        let memory = PersonalMemory(content: "Old")
        context.insert(memory)
        XCTAssertTrue(try PersonalMemory.prompt(in: context).text.contains("Old"))
        memory.content = "New"
        XCTAssertFalse(try PersonalMemory.prompt(in: context).text.contains("Old"))
        memory.isEnabled = false
        XCTAssertEqual(try PersonalMemory.prompt(in: context).count, 0)
        context.delete(memory); try context.save()
        XCTAssertEqual(try PersonalMemory.prompt(in: context).text, "")
    }

    func testRoutingUsesLiveCapabilitiesPrioritizesImagesAndKeepsInputWhenUnavailable() async throws {
        let a = provider("text"), image = provider("vision", vision: true), code = provider("code")
        let c = conversation(a)
        c.assistanceSettings.automaticRouting = true
        c.assistanceSettings.imageTarget = target(image)
        c.assistanceSettings.codeTarget = target(code)
        let capture = PhaseThreeCapture(), engine = ChatEngine { r in capture.append(r); return Self.success() }
        let attachment = MessageAttachment(kind: .image, fileName: "test.png", mimeType: "image/png", dataBase64: "eA==", byteSize: 1)
        _ = engine.sendUserMessage(text: "```swift\nlet x = 1\n```", attachments: [attachment], in: c, providers: [a,image,code], context: context)
        try await wait(engine,c)
        XCTAssertEqual(capture.requests.first?.modelID, "vision")
        XCTAssertEqual(c.primaryTarget?.modelID, "text")
        XCTAssertNotNil(c.sortedMessages.last?.assistanceMetadata.routeNotice)
        let count = c.messages.count
        image.isEnabled = false
        XCTAssertEqual(engine.sendUserMessage(text: "image", attachments: [attachment], in: c, providers: [a,image,code], context: context), .noAvailableModel)
        XCTAssertEqual(c.messages.count,count)
        _ = engine.sendUserMessage(text: "```print(1)```", attachments: [], in: c, providers: [a,image,code], context: context)
        try await wait(engine,c)
        XCTAssertEqual(capture.requests.last?.modelID,"code")
    }

    func testFallbackPolicyOnlyAllowsSpecifiedErrorsBeforeAnyOutput() {
        for code in [429,502,503,504] { XCTAssertTrue(AssistancePolicy.mayFallback(LLMError.httpError(code,"x"), receivedOutput:false, abnormalFinish:false)) }
        for code in [400,401,403,404,500] { XCTAssertFalse(AssistancePolicy.mayFallback(LLMError.httpError(code,"x"), receivedOutput:false, abnormalFinish:false)) }
        XCTAssertTrue(AssistancePolicy.mayFallback(URLError(.timedOut), receivedOutput:false, abnormalFinish:false))
        for error in [CancellationError() as Error, URLError(.cancelled), URLError(.notConnectedToInternet), LLMError.interruptedStream] {
            XCTAssertFalse(AssistancePolicy.mayFallback(error, receivedOutput:false, abnormalFinish:false))
        }
        XCTAssertFalse(AssistancePolicy.mayFallback(URLError(.timedOut), receivedOutput:true, abnormalFinish:false))
        XCTAssertFalse(AssistancePolicy.mayFallback(URLError(.timedOut), receivedOutput:false, abnormalFinish:true))
    }

    func testFallbackAttemptsShareOperationButKeepSeparatePriceUsageAndActualIdentity() async throws {
        let a=provider("a"), b=provider("b"), c=conversation(a,backups:[b])
        let capture=PhaseThreeCapture()
        let engine=ChatEngine { r in
            capture.append(r)
            if r.modelID == "a" {
                return AsyncThrowingStream { s in s.yield(.retrying(httpStatus:400)); s.finish(throwing:LLMError.httpError(502,"gateway")) }
            }
            return Self.success("Backup answer")
        }
        _=engine.sendUserMessage(text:"Question",attachments:[],in:c,providers:[a,b],context:context)
        try await wait(engine,c)
        XCTAssertEqual(capture.requests.map(\.modelID),["a","b"])
        let records=try context.fetch(FetchDescriptor<RequestRecord>()).sorted { $0.attempt < $1.attempt }
        XCTAssertEqual(records.map(\.attempt),[1,2,3])
        XCTAssertEqual(Set(records.map(\.operationID)).count,1)
        XCTAssertEqual(records.map(\.status),[.failed,.failed,.succeeded])
        XCTAssertEqual(records.map(\.httpStatus),[400,502,nil])
        XCTAssertNil(records.first?.estimatedCost)
        XCTAssertNotNil(records.last?.estimatedCost)
        let answer=c.sortedMessages.last!
        XCTAssertEqual(answer.content,"Backup answer"); XCTAssertEqual(answer.providerID,b.id)
        XCTAssertEqual(answer.assistanceMetadata.fallbackNotices.count,1)
        XCTAssertEqual(answer.latestRequest?.attempt,3)
    }

    func testPartialReasoningOrTextNeverFallsBack() async throws {
        for reasoning in [false,true] {
            let a=provider(UUID().uuidString), b=provider(UUID().uuidString), c=conversation(a,backups:[b])
            let capture=PhaseThreeCapture()
            let engine=ChatEngine { r in
                capture.append(r)
                return AsyncThrowingStream { s in
                    s.yield(reasoning ? .reasoningDelta("partial") : .contentDelta("partial"))
                    s.finish(throwing:URLError(.timedOut))
                }
            }
            _=engine.sendUserMessage(text:"q",attachments:[],in:c,providers:[a,b],context:context)
            try await wait(engine,c)
            XCTAssertEqual(capture.requests.count,1)
            XCTAssertEqual(reasoning ? c.sortedMessages.last?.reasoningContent : c.sortedMessages.last?.content,"partial")
            XCTAssertNotNil(c.sortedMessages.last?.errorMessage)
        }
    }

    func testFallbackChainDeduplicatesFiltersDisabledAndIncapableModelsAndHasBound() {
        let a=provider("a",vision:true), b=provider("b"), d=provider("disabled",vision:true,enabled:false), e=provider("e",vision:true)
        var settings=AssistanceSettings(); settings.fallbackEnabled=true
        settings.fallbackTargets=[target(a),target(e),target(e),target(b)]
        XCTAssertEqual(AssistancePolicy.fallbacks(after:target(a),settings:settings,providers:[a,b,d,e],requiresVision:true).map(\.id),[target(e).id])
        settings.fallbackTargets=[target(b),target(d),target(e)]
        XCTAssertEqual(AssistancePolicy.fallbacks(after:target(a),settings:settings,providers:[a,b,d,e],requiresVision:true).map(\.id),[target(e).id])
    }

    func testArenaDoesNotRouteOrFallbackAndSearchesOnlyOnce() async throws {
        let a=provider("a"), b=provider("b"), fallback=provider("fallback"), c=conversation(a,backups:[fallback])
        c.isArenaMode=true; c.arenaTargets=[target(a),target(b)]
        c.assistanceSettings.automaticRouting=true; c.assistanceSettings.codeTarget=target(fallback)
        let capture=PhaseThreeCapture()
        let engine=ChatEngine(search:{ q in capture.append(query:q); return Self.evidence(q) },stream:{ r in
            capture.append(r)
            if r.modelID == "a" { return AsyncThrowingStream { $0.finish(throwing:LLMError.httpError(502,"x")) } }
            return Self.success()
        })
        _=engine.sendUserMessage(text:"```question```",attachments:[],in:c,providers:[a,b,fallback],context:context,options:GenerationOptions(searchQuery:"public query"))
        try await wait(engine,c)
        XCTAssertEqual(Set(capture.requests.map(\.modelID)),Set(["a","b"]))
        XCTAssertEqual(capture.searchQueries,["public query"])
        XCTAssertTrue(capture.requests.allSatisfy { $0.messages.last!.content.contains("https://example.com/source") })
        XCTAssertEqual(try context.fetch(FetchDescriptor<RequestRecord>()).filter { $0.kind == .webSearch }.count,1)
        XCTAssertTrue(c.messages.filter { $0.role == .assistant }.allSatisfy { $0.assistanceMetadata.search?.sources.count == 1 })
    }

    func testSearchReceivesOnlyExplicitQueryAndMemoryStaysInModelPrompt() async throws {
        let p=provider("a"), c=conversation(p)
        c.assistanceSettings.usePersonalMemory=true
        context.insert(PersonalMemory(content:"PRIVATE_MEMORY"))
        let capture=PhaseThreeCapture()
        let engine=ChatEngine(search:{ q in capture.append(query:q); return Self.evidence(q) }, stream:{ r in capture.append(r); return Self.success() })
        _=engine.sendUserMessage(text:"PRIVATE_QUESTION",attachments:[],in:c,providers:[p],context:context,options:GenerationOptions(searchQuery:"public query"))
        try await wait(engine,c)
        XCTAssertEqual(capture.searchQueries,["public query"])
        XCTAssertTrue(capture.requests.first!.systemPrompt.contains("PRIVATE_MEMORY"))
        XCTAssertTrue(capture.requests.first!.messages.last!.content.contains("untrusted reference material"))
        XCTAssertEqual(c.messages.first { $0.role == .user }?.content,"PRIVATE_QUESTION")
        let record=try context.fetch(FetchDescriptor<RequestRecord>()).first { $0.kind == .webSearch }!
        XCTAssertNil(record.promptTokens); XCTAssertNil(record.estimatedCost); XCTAssertNil(record.tokensPerSecond)
    }

    func testSearchFailureStopsModelAndPreservesQuestionAndRetryQuery() async throws {
        let p=provider("a"), c=conversation(p), capture=PhaseThreeCapture()
        let engine=ChatEngine(search:{ _ in throw SearchError.http(429) },stream:{ r in capture.append(r); return Self.success() })
        _=engine.sendUserMessage(text:"Question",attachments:[],in:c,providers:[p],context:context,options:GenerationOptions(searchQuery:"query"))
        try await wait(engine,c)
        XCTAssertTrue(capture.requests.isEmpty)
        XCTAssertEqual(c.sortedMessages.first?.content,"Question")
        XCTAssertEqual(c.sortedMessages.last?.assistanceMetadata.requestedSearchQuery,"query")
        XCTAssertNotNil(c.sortedMessages.last?.errorMessage)
        let records=try context.fetch(FetchDescriptor<RequestRecord>())
        XCTAssertEqual(records.count,1); XCTAssertEqual(records[0].httpStatus,429)
        XCTAssertEqual(records[0].status,.failed)
    }

    func testCancelDuringSearchNeverStartsModelAndFinishesLedger() async throws {
        let p=provider("a"), c=conversation(p), capture=PhaseThreeCapture()
        let engine=ChatEngine(search:{ q in
            capture.append(query:q)
            try await Task.sleep(for:.seconds(20)); return Self.evidence(q)
        },stream:{ r in capture.append(r); return Self.success() })
        _=engine.sendUserMessage(text:"q",attachments:[],in:c,providers:[p],context:context,options:GenerationOptions(searchQuery:"query"))
        while capture.searchQueries.isEmpty { try await Task.sleep(for:.milliseconds(5)) }
        await engine.stopGenerationAndWait(for:c.id)
        XCTAssertTrue(capture.requests.isEmpty)
        XCTAssertFalse(c.sortedMessages.last!.isStreaming)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RequestRecord>()).first?.status,.cancelled)
    }

    func testInvalidSearchDoesNotConsumeComposerOrCreateMessages() {
        let p=provider("a"), c=conversation(p), engine=ChatEngine()
        for query in [" ",String(repeating:"a",count:401)] {
            XCTAssertEqual(engine.sendUserMessage(text:"keep me",attachments:[],in:c,providers:[p],context:context,options:GenerationOptions(searchQuery:query)),.invalidSearch)
        }
        XCTAssertTrue(c.messages.isEmpty)
    }

    func testSearchHTTPContractAndBoundedDecode() async throws {
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[SearchFixtureProtocol.self]
        let session=URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let evidence=try await TavilySearchClient.search(query:"fixture query",apiKey:"fixture",session:session)
        XCTAssertEqual(evidence.sources.count,1); XCTAssertEqual(evidence.credits,1)
        let request=try XCTUnwrap(SearchFixtureProtocol.requests.last)
        XCTAssertEqual(request.url?.absoluteString,"https://api.tavily.com/search")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer fixture")
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(request.httpBody)) as? [String:Any])
        XCTAssertEqual(body["query"] as? String,"fixture query")
        XCTAssertEqual(body["auto_parameters"] as? Bool,false)
        XCTAssertEqual(body["include_answer"] as? Bool,false)
        XCTAssertEqual(body["max_results"] as? Int,5)
        for key in ["failure","large"] {
            do { _=try await TavilySearchClient.search(query:"q",apiKey:key,session:session); XCTFail("Expected rejection") }
            catch { XCTAssertTrue(error is SearchError) }
        }
        do { _=try await TavilySearchClient.search(query:"q",apiKey:"",session:session); XCTFail("Missing key") }
        catch { XCTAssertTrue(error is SearchError) }
    }

    func testSearchSourcesFilterUnsafeLinksDeduplicateAndBoundSnippets() throws {
        let items: [[String:String]] = [
            ["url":"javascript:alert(1)","content":"bad"], ["url":"https://localhost","content":"bad"],
            ["url":"https://user:pass@example.com","content":"bad"],
            ["url":"https://example.com/a","title":"Reference","content":String(repeating:"x",count:2500)],
            ["url":"https://example.com/a","content":"duplicate"]
        ]
        let evidence=try TavilySearchClient.decode(JSONSerialization.data(withJSONObject:["results":items]),query:"q")
        XCTAssertEqual(evidence.sources.count,1); XCTAssertEqual(evidence.sources[0].snippet.count,2000)
        XCTAssertThrowsError(try TavilySearchClient.decode(Data(#"{"results":[]}"#.utf8),query:"q"))
        XCTAssertThrowsError(try TavilySearchClient.decode(Data("not json".utf8),query:"q"))
    }

    func testBackupRoundTripPreservesMemoriesRoutingEvidenceAndOlderFormatDefaults() throws {
        let a=provider("a"),b=provider("b"),c=conversation(a,backups:[b])
        c.assistanceSettings.usePersonalMemory=true
        context.insert(PersonalMemory(content:"Memory"))
        let m=ChatMessage(role:.assistant,content:"Answer"); m.conversation=c; context.insert(m)
        m.assistanceMetadata.search=Self.evidence("q")
        let archive=try BackupService.makeArchive(context:context)
        let data=try BackupService.encode(archive)
        let other=try ModelContainer(for:Schema(versionedSchema:CurrentSchema.self),configurations:ModelConfiguration(isStoredInMemoryOnly:true))
        let summary=try BackupService.apply(BackupService.decode(data),to:other.mainContext)
        XCTAssertEqual(summary.memories,1)
        let restored=try XCTUnwrap(other.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(restored.assistanceSettings,c.assistanceSettings)
        XCTAssertEqual(restored.sortedMessages.first?.assistanceMetadata.search?.sources.first?.url.absoluteString,"https://example.com/source")
        XCTAssertEqual(try BackupService.apply(BackupService.decode(data),to:other.mainContext).memories,0)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        json["formatVersion"]=3; json.removeValue(forKey:"memories")
        var convs=json["conversations"] as! [[String:Any]]
        for i in convs.indices { convs[i].removeValue(forKey:"assistanceSettings") }
        json["conversations"]=convs
        guard case .full(let old)=try BackupService.decode(JSONSerialization.data(withJSONObject:json)) else { return XCTFail() }
        XCTAssertNil(old.memories); XCTAssertNil(old.conversations.first?.assistanceSettings)
    }

    func testInvalidMemoryBackupIsAtomic() throws {
        var archive=try BackupService.makeArchive(context:context)
        archive.memories=[PersonalMemory.Snapshot(id:UUID(),content:String(repeating:"x",count:501),isEnabled:true,createdAt:Date())]
        XCTAssertThrowsError(try BackupService.apply(.full(archive),to:context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalMemory>()),0)
    }

    func testV3MigrationPreservesLedgerRelationshipSynthesisAndDefaults() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("phase3-migration-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("store"), operation=UUID(), messageID=UUID(), conversationID=UUID()
        let p=provider("fixture"), model=target(p)
        do {
            let schema=Schema(versionedSchema:SchemaV3.self)
            let old=try ModelContainer(for:schema,configurations:ModelConfiguration(schema:schema,url:url))
            let context=ModelContext(old)
            let c=SchemaV3.Conversation(id:conversationID,title:"V3")
            let m=SchemaV3.ChatMessage(id:messageID,role:.assistant,content:"Summary")
            let record=SchemaV3.RequestRecord(target:model,spec:p.models[0],conversationID:conversationID,messageID:messageID,kind:.synthesis,operationID:operation)
            record.statusRaw="succeeded"; record.promptTokens=10; record.completionTokens=20
            m.latestRequest=record; m.synthesisSourceDigest="digest"; m.conversation=c
            context.insert(c); context.insert(m); context.insert(record); try context.save()
        }
        let schema=Schema(versionedSchema:CurrentSchema.self)
        let migrated=try PersistenceController.open(schema:schema,configuration:ModelConfiguration(schema:schema,url:url))
        let context=ModelContext(migrated)
        let c=try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        let m=try XCTUnwrap(context.fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertEqual(c.id,conversationID); XCTAssertEqual(c.assistanceSettings,AssistanceSettings())
        XCTAssertEqual(m.synthesisSourceDigest,"digest"); XCTAssertEqual(m.latestRequest?.operationID,operation)
        XCTAssertEqual(m.latestRequest?.completionTokens,20); XCTAssertNil(m.assistanceMetadata.search)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalMemory>()),0)
    }
}
