import Foundation

enum WebpageApprovalDecision: Sendable, Equatable {
    case allow
    case deny
}

enum AgentToolRunner {
    static let maxToolRounds = 3
    static let maxCallsPerTurn = 6
    static let maxSearchesPerTurn = 3

    /// Extracts canonicalized `https://` URLs explicitly typed by the user so user-supplied links
    /// do not trigger redundant confirmation prompts, while model-invented or prompt-injected URLs
    /// (including query-string exfiltration variants) always require user approval.
    static func extractUserProvidedURLs(from texts: [String]) -> Set<String> {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var allowed = Set<String>()
        for text in texts where !text.isEmpty {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: nsRange) {
                if let url = match.url, url.scheme?.lowercased() == "https" {
                    allowed.insert(canonicalURLKey(url))
                }
            }
        }
        return allowed
    }

    static func canonicalURLKey(_ url: URL) -> String {
        URLReader.requestIdentity(url)
    }

    static func definitions(hasTavilyKey: Bool, hasKnowledgeBase: Bool = false) -> [LLMToolDefinition] {
        var tools: [LLMToolDefinition] = [
            LLMToolDefinition(
                name: "read_webpage",
                description: "Read the main text content of a public HTTPS webpage URL when the user provides a URL or asks to inspect a specific page.",
                parametersSchemaJSON: """
                {"type":"object","properties":{"url":{"type":"string","description":"Public HTTPS webpage URL to read"}},"required":["url"]}
                """
            ),
            LLMToolDefinition(
                name: "propose_memory",
                description: "Suggest a concise long-term personal preference or background fact for the user to optionally save (only when the user explicitly states a durable preference or background).",
                parametersSchemaJSON: """
                {"type":"object","properties":{"fact":{"type":"string","description":"Concise user preference or background fact (max 200 chars)"}},"required":["fact"]}
                """
            ),
            LLMToolDefinition(
                name: "propose_schedule_item",
                description: "Propose a reminder to-do or calendar event for the user to review and optionally add to their iOS Reminders or Calendar when the user asks to plan, schedule, or track an action item.",
                parametersSchemaJSON: """
                {"type":"object","properties":{"kind":{"type":"string","enum":["reminder","calendar"],"description":"reminder for to-do task, calendar for timed event"},"title":{"type":"string","description":"Actionable title"},"notes":{"type":"string","description":"Optional notes or context"},"scheduledAt":{"type":"string","description":"Optional local date/time yyyy-MM-dd HH:mm"},"durationMinutes":{"type":"integer","description":"Event duration in minutes (default 60)"}},"required":["kind","title"]}
                """
            )
        ]

        if hasKnowledgeBase {
            tools.insert(
                LLMToolDefinition(
                    name: "search_documents",
                    description: "Search across the user's bound local reference documents (PDFs, EPUBs, Markdown, books) by keywords or question to retrieve exact cited passages.",
                    parametersSchemaJSON: """
                    {"type":"object","properties":{"query":{"type":"string","description":"Focused search terms or question to look up in bound documents"}},"required":["query"]}
                    """
                ),
                at: 0
            )
        }

        if hasTavilyKey {
            tools.insert(
                LLMToolDefinition(
                    name: "web_search",
                    description: "Search the web for current facts, documentation, news, or verification.",
                    parametersSchemaJSON: """
                    {"type":"object","properties":{"query":{"type":"string","description":"Concise search query (1-400 characters)"}},"required":["query"]}
                    """
                ),
                at: 0
            )
        }
        return tools
    }

    struct ExecutionOutput {
        let toolOutputJSON: String
        let record: ToolCallRecord
        let searchEvidence: SearchEvidence?
        let knowledgeEvidence: KnowledgeEvidence?
        let proposedMemory: String?
        let proposedSchedule: ProposedScheduleItem?
        let error: Error?

        init(
            toolOutputJSON: String,
            record: ToolCallRecord,
            searchEvidence: SearchEvidence? = nil,
            knowledgeEvidence: KnowledgeEvidence? = nil,
            proposedMemory: String? = nil,
            proposedSchedule: ProposedScheduleItem? = nil,
            error: Error? = nil
        ) {
            self.toolOutputJSON = toolOutputJSON
            self.record = record
            self.searchEvidence = searchEvidence
            self.knowledgeEvidence = knowledgeEvidence
            self.proposedMemory = proposedMemory
            self.proposedSchedule = proposedSchedule
            self.error = error
        }
    }

    static func execute(
        _ call: LLMToolCall,
        searchHandler: @Sendable (String) async throws -> SearchEvidence,
        webpageHandler: (@Sendable (URL) async throws -> ReadablePage)? = nil,
        webpageApproval: (@Sendable (URL) async -> WebpageApprovalDecision)? = nil,
        knowledgeHandler: (@Sendable (String) async throws -> KnowledgeEvidence)? = nil
    ) async -> ExecutionOutput {
        let args = call.argumentsDictionary

        switch call.name {
        case "web_search":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                let err = #"{"error":"Missing search query"}"#
                return ExecutionOutput(
                    toolOutputJSON: err,
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: "", resultSummary: String(localized: "缺少搜索词"), succeeded: false)
                )
            }
            do {
                let evidence = try await searchHandler(String(query.prefix(TavilySearchClient.maximumQueryCharacters)))
                return ExecutionOutput(
                    toolOutputJSON: evidence.prompt,
                    record: ToolCallRecord(
                        id: call.id,
                        name: call.name,
                        argumentsSummary: query,
                        resultSummary: String(localized: "\(evidence.sources.count) 个来源"),
                        succeeded: true
                    ),
                    searchEvidence: evidence
                )
            } catch {
                let err = jsonError(error.localizedDescription)
                return ExecutionOutput(
                    toolOutputJSON: err,
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: query, resultSummary: error.localizedDescription, succeeded: false),
                    error: error
                )
            }

        case "search_documents":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return ExecutionOutput(
                    toolOutputJSON: jsonError("Missing document search query"),
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: "", resultSummary: String(localized: "缺少搜索词"), succeeded: false)
                )
            }
            guard let knowledgeHandler else {
                return ExecutionOutput(
                    toolOutputJSON: jsonError("No reference documents are bound to this conversation"),
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: query, resultSummary: String(localized: "未绑定文档"), succeeded: false)
                )
            }
            do {
                let evidence = try await knowledgeHandler(String(query.prefix(400)))
                let promptText = evidence.promptText()
                return ExecutionOutput(
                    toolOutputJSON: promptText.isEmpty ? #"{"matches":[]}"# : promptText,
                    record: ToolCallRecord(
                        id: call.id,
                        name: call.name,
                        argumentsSummary: query,
                        resultSummary: evidence.passages.isEmpty ? String(localized: "未找到相关原文") : String(localized: "\(evidence.passages.count) 处片段"),
                        succeeded: true
                    ),
                    knowledgeEvidence: evidence
                )
            } catch {
                return ExecutionOutput(
                    toolOutputJSON: jsonError(error.localizedDescription),
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: query, resultSummary: error.localizedDescription, succeeded: false),
                    error: error
                )
            }

        case "read_webpage":
            let rawURL = (args["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: rawURL) else {
                return ExecutionOutput(
                    toolOutputJSON: jsonError("Invalid URL"),
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: rawURL, resultSummary: String(localized: "无效链接"), succeeded: false)
                )
            }
            do {
                try URLReader.validate(url)
                if let webpageApproval {
                    let decision = await webpageApproval(url)
                    if decision == .deny {
                        return ExecutionOutput(
                            toolOutputJSON: jsonError("User declined reading external webpage"),
                            record: ToolCallRecord(
                                id: call.id,
                                name: call.name,
                                argumentsSummary: url.host ?? rawURL,
                                resultSummary: String(localized: "用户已拒绝访问"),
                                succeeded: false
                            )
                        )
                    }
                }
                let page: ReadablePage
                if let webpageHandler {
                    page = try await webpageHandler(url)
                } else {
                    try AppCompliance.requireConsent()
                    page = try await URLReader.read(url, authorizeRedirect: {
                        guard let webpageApproval else { return false }
                        return await webpageApproval($0) == .allow
                    })
                }
                let payload: [String: Any] = [
                    "url": page.url.absoluteString,
                    "title": page.title,
                    "text": String(page.text.prefix(12_000)),
                    "truncated": page.isTruncated || page.text.count > 12_000
                ]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                let text = "Untrusted webpage reference:\n" + String(decoding: data, as: UTF8.self)
                return ExecutionOutput(
                    toolOutputJSON: text,
                    record: ToolCallRecord(
                        id: call.id,
                        name: call.name,
                        argumentsSummary: url.host ?? rawURL,
                        resultSummary: page.title.isEmpty ? String(localized: "已完成") : String(page.title.prefix(60)),
                        succeeded: true
                    )
                )
            } catch {
                return ExecutionOutput(
                    toolOutputJSON: jsonError(error.localizedDescription),
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: rawURL, resultSummary: error.localizedDescription, succeeded: false),
                    error: error
                )
            }

        case "propose_memory":
            let fact = (args["fact"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty else {
                return ExecutionOutput(
                    toolOutputJSON: jsonError("Empty memory fact"),
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: "", resultSummary: String(localized: "内容为空"), succeeded: false)
                )
            }
            let bounded = String(fact.prefix(PersonalMemory.maximumCharacters))
            return ExecutionOutput(
                toolOutputJSON: #"{"status":"proposed_for_user_confirmation"}"#,
                record: ToolCallRecord(
                    id: call.id,
                    name: call.name,
                    argumentsSummary: String(bounded.prefix(80)),
                    resultSummary: String(localized: "待用户确认"),
                    succeeded: true
                ),
                proposedMemory: bounded
            )

        case "propose_schedule_item":
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return ExecutionOutput(
                    toolOutputJSON: jsonError("Empty schedule item title"),
                    record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: "", resultSummary: String(localized: "内容为空"), succeeded: false)
                )
            }
            let kindRaw = (args["kind"] as? String ?? "reminder").lowercased()
            let kind: ProposedScheduleItem.Kind = kindRaw.contains("calendar") ? .calendarEvent : .reminder
            let notes = (args["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedDate = ProposedScheduleItem.parseFlexibleDateWithPrecision(args["scheduledAt"] as? String)
            let duration = (args["durationMinutes"] as? Int) ?? 60
            let item = ProposedScheduleItem(
                kind: kind,
                title: title,
                notes: notes,
                scheduledAt: parsedDate.date,
                durationMinutes: duration,
                isDateOnly: parsedDate.isDateOnly
            )
            return ExecutionOutput(
                toolOutputJSON: #"{"status":"proposed_for_user_confirmation"}"#,
                record: ToolCallRecord(
                    id: call.id,
                    name: call.name,
                    argumentsSummary: "\(kind.badgeTitle) · \(String(title.prefix(60)))",
                    resultSummary: String(localized: "待用户确认"),
                    succeeded: true
                ),
                proposedSchedule: item
            )

        default:
            return ExecutionOutput(
                toolOutputJSON: jsonError("Unsupported tool: \(call.name)"),
                record: ToolCallRecord(id: call.id, name: call.name, argumentsSummary: call.argumentsJSON, resultSummary: String(localized: "不支持的工具"), succeeded: false)
            )
        }
    }

    private static func jsonError(_ message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
