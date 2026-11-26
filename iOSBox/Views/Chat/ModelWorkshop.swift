#if canImport(FoundationModels)
import FoundationModels
#endif
import SwiftData
import SwiftUI

enum LabMode: String, Identifiable, CaseIterable {
    case blind = "盲测题库", extract = "资料提取表", review = "接力审稿", local = "本机摘要与改写"
    var id: Self { self }
    var title: String {
        switch self {
        case .blind: String(localized: "盲测题库")
        case .review: String(localized: "接力审稿")
        case .extract: String(localized: "资料提取表")
        case .local: String(localized: "本机摘要与改写")
        }
    }
}

struct BlindCase: Codable, Identifiable {
    var id = UUID()
    var prompt: String
    var rubric: String
    var attachments: [MessageAttachment]
    var rounds: [Round] = []
    struct Answer: Codable, Identifiable {
        var id = UUID()
        let model: String
        let text: String
        let cost: String
        let seconds: Double
        var failed: Bool? = nil
    }
    struct Round: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let answers: [Answer]
        var vote: String?
    }
}

@MainActor enum BlindLibrary {
    static func url() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ModelEvaluationCases.json")
    }
    static func read() throws -> [BlindCase] {
        let file = try url()
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([BlindCase].self, from: Data(contentsOf: file))
    }
    static func change(_ edit: (inout [BlindCase]) throws -> Void) throws -> [BlindCase] {
        var cases = try read()
        try edit(&cases)
        try JSONEncoder().encode(cases).write(to: url(), options: [.atomic, .completeFileProtection])
        return cases
    }
}

struct ModelWorkshop: View {
    let mode: LabMode
    var initialAttachments: [MessageAttachment] = []
    @State var input: String = ""
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \BookVolume.title) private var books: [BookVolume]
    @State private var primary = ""
    @State private var secondary = ""
    @State private var rubric = ""
    @State private var cases: [BlindCase] = []
    @State private var caseID: UUID?
    @State private var blindModels = Set<String>()
    @State private var selectedBooks = Set<UUID>()
    @State private var fields = "项目,数量,单价,币种"
    @State private var rows: [ExtractCell] = []
    @State private var draft = ""
    @State private var patch: DraftRevision?
    @State private var accepted = Set<Int>()
    @State private var critique = ""
    @State private var revision = ""
    @State private var localAction = "摘要"
    @State private var issue = ""
    @State private var task: Task<Void, Never>?
    @State private var consent = AIConsentGate()
    @State private var exportURL: URL?
    @Environment(\.scenePhase) private var phase

    private var options: [TaskModel] { TaskModel.options(providers) }
    private var current: BlindCase? { cases.first { $0.id == caseID } }
    private var columns: [String] {
        fields.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    struct ExtractCell: Identifiable, Equatable {
        var id = UUID()
        var value: String
        let column: String
        let row: Int
        let source: ReadingCitation?
    }
    var body: some View {
        Form {
            Group {
                if mode == .blind { blindControls }
                if mode == .extract { extractionControls }
                if mode == .blind || mode == .review || mode == .local {
                    Section(mode == .local ? "原文" : "任务") {
                        TextField("输入或粘贴文本", text: $input, axis: .vertical).lineLimit(3...10)
                            .accessibilityIdentifier("modelWorkshop.input")
                    }
                }
                if mode == .local {
                    Picker("操作", selection: $localAction) { ForEach(["摘要","改写","提取标签"], id: \.self) { Text($0) } }
                }
                if mode == .review || mode == .extract {
                    TaskModelPicker(providers: providers, choice: $primary, title: mode == .review ? "起草与修订" : "提取模型")
                    if mode == .review { TaskModelPicker(providers: providers, choice: $secondary, title: "审校") }
                }
            }.disabled(task != nil)
            if mode == .review || mode == .blind { pricingPreview }
            if task == nil { Button(action: begin) { Text(runLabel) } }
            else { Button("停止任务") { task?.cancel() }; ProgressView() }
            if !issue.isEmpty { Text(issue).foregroundStyle(.secondary) }
            if mode == .blind { blindResults }
            if mode == .extract { extractionResults }
            if !draft.isEmpty { Section("原稿") { Text(draft).textSelection(.enabled) } }
            if !critique.isEmpty { Section("审校意见") { Text(critique).textSelection(.enabled) } }
            if !revision.isEmpty || (mode == .review && patch != nil) {
                if mode == .review, let patch {
                    Section("逐项采纳修订") {
                        ForEach(patch.changes.filter(\.changed)) { edit in
                            Toggle(isOn: Binding(get: { accepted.contains(edit.id) }, set: { on in
                                if on { accepted.insert(edit.id) } else { accepted.remove(edit.id) }
                                revision = patch.text(accepting: accepted)
                            })) {
                                VStack(alignment: .leading) {
                                    ForEach(edit.before.indices, id: \.self) { Text("− " + edit.before[$0]).foregroundStyle(.red) }
                                    ForEach(edit.after.indices, id: \.self) { Text("+ " + edit.after[$0]).foregroundStyle(.green) }
                                }
                            }
                        }
                    }
                }
                Section("结果（可编辑）") { TextEditor(text: $revision).frame(minHeight: 120); ShareLink(item: revision) }
            }
        }.navigationTitle(mode.title).aiConsentSheet(consent)
        .onChange(of: rows) { exportURL = nil }
        .onAppear { if mode == .blind { do { cases = try BlindLibrary.read() } catch { issue = error.localizedDescription } } }
        .onDisappear { task?.cancel() }.onChange(of: phase) { if phase == .background { task?.cancel() } }
    }
    @ViewBuilder private var pricingPreview: some View {
        let models = mode == .blind ? options.filter { blindModels.contains($0.id) } :
            [primary, secondary, primary].compactMap { key in options.first { $0.id == key } }
        if !models.isEmpty {
            let base = TokenEstimator.estimateTokens(for: input, attachments: mode == .blind ? current?.attachments ?? initialAttachments : [])
            let totals = models.enumerated().reduce(into: [String: Double]()) { sums, pair in
                let (step, model) = pair
                guard let rates = ModelPricingDisplay.configuredRates(for: model.spec) else { return }
                let context = base + (mode == .review ? step * 2048 : 0)
                sums[rates.currency, default: 0] += (Double(context) * rates.input + 2048 * rates.output) / 1_000_000
            }
            Section("运行前费用预估") {
                ForEach(totals.keys.sorted(), id: \.self) { currency in
                    Text(RequestLedger.costText(totals[currency, default: 0], currency: currency))
                }
                if models.contains(where: { ModelPricingDisplay.configuredRates(for: $0.spec) == nil }) {
                    Text("部分模型单价未知")
                }
                Text("按每步最多 2,048 个输出 Token 估算；服务商实际用量及重试会影响最终费用。").font(.caption)
            }
        }
    }
    private var runLabel: String {
        switch mode {
        case .blind: "保存并盲测（\(blindModels.count) 次请求）"
        case .extract: "发送所选资料并提取"
        case .review: "起草、审校并修订（3 次请求）"
        case .local: "在本机运行"
        }
    }
    @ViewBuilder private var blindControls: some View {
        Section("题库") {
            Picker("题目", selection: $caseID) {
                Text("新题目").tag(nil as UUID?)
                ForEach(cases) { Text(String($0.prompt.prefix(45))).tag(Optional($0.id)) }
            }.onChange(of: caseID) { if let current { input = current.prompt; rubric = current.rubric } }
            if let current { Button("删除这道题", role: .destructive) {
                do { cases = try BlindLibrary.change { $0.removeAll { $0.id == current.id } }; caseID = nil }
                catch { issue = error.localizedDescription }
            } }
            TextField("评分标准", text: $rubric)
            Button("仅保存题目") {
                guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do {
                    let item = BlindCase(prompt: input, rubric: rubric, attachments: current?.attachments ?? initialAttachments)
                    cases = try BlindLibrary.change { $0.append(item) }
                    caseID = item.id
                } catch { issue = error.localizedDescription }
            }.disabled(input.isEmpty || (current?.prompt == input && current?.rubric == rubric))
            let attachments = current?.attachments ?? initialAttachments
            ForEach(attachments) { Text($0.fileName).font(.caption) }
        }
        Section("选择 2–4 个模型") {
            ForEach(options) { model in
                Toggle(model.recipient, isOn: Binding(get: { blindModels.contains(model.id) }, set: { on in
                    if on { if blindModels.count < 4 { blindModels.insert(model.id) } } else { blindModels.remove(model.id) }
                }))
            }
        }
    }
    @ViewBuilder private var blindResults: some View {
        if let current {
            ForEach(current.rounds.reversed()) { round in
                Section(round.date.formatted()) {
                    ForEach(Array(round.answers.enumerated()), id: \.element.id) { index, answer in
                        Text("回答 \(index + 1)").bold()
                        Text(answer.text).textSelection(.enabled)
                        if round.vote != nil {
                            Text("\(answer.model) · \(answer.seconds.formatted()) s · \(answer.cost)").font(.caption)
                        } else if answer.failed != true { Button("采纳回答 \(index + 1)") { vote("回答 \(index + 1)", round: round.id) } }
                    }
                    if let vote = round.vote { Text("选择 · " + vote) }
                    else { Button("平局") { vote("平局", round: round.id) }; Button("都不满意") { vote("都不满意", round: round.id) } }
                }
            }
        }
    }
    private func vote(_ value: String, round: UUID) {
        do {
            cases = try BlindLibrary.change { saved in
                guard let i = saved.firstIndex(where: { $0.id == caseID }),
                      let j = saved[i].rounds.firstIndex(where: { $0.id == round }) else { return }
                saved[i].rounds[j].vote = value
            }
        } catch { issue = error.localizedDescription }
    }
    @ViewBuilder private var extractionControls: some View {
        Section("发送完整正文的资料") {
            ForEach(books) { book in
                Toggle(book.title, isOn: Binding(get: { selectedBooks.contains(book.id) }, set: { on in
                    if on { selectedBooks.insert(book.id) } else { selectedBooks.remove(book.id) }
                }))
            }
        }
        TextField("字段（逗号分隔）", text: $fields)
    }
    @ViewBuilder private var extractionResults: some View {
        if !rows.isEmpty {
            ForEach($rows) { $cell in
                VStack(alignment: .leading) {
                    Text("第 \(cell.row) 行 · \(cell.column)").font(.caption)
                    TextField(cell.column, text: $cell.value)
                    if let source = cell.source { NavigationLink(source.marker) { SourceReader(source: source) } }
                }
            }
            Button("生成 CSV") {
                do {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("提取-\(UUID()).csv")
                    try Self.csv(rows).write(to: url, atomically: true, encoding: .utf8)
                    exportURL = url
                } catch { issue = error.localizedDescription }
            }
            if let exportURL { ShareLink(item: exportURL) }
        }
    }
    static func csv(_ cells: [ExtractCell]) -> String {
        func escape(_ value: String) -> String {
            let safe = value.first.map { "=+-@\t\r".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = cells.filter { $0.row == 1 }.map(\.column)
        let grouped = Dictionary(grouping: cells, by: \.row)
        let data = grouped.keys.sorted().map { row in (grouped[row] ?? []).map(\.value) }
        return "\u{feff}" + ([header] + data).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
    }
    private func begin() {
        issue = ""
        guard mode == .extract || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { issue = "请输入内容"; return }
        let models: [TaskModel]
        switch mode {
        case .blind:
            models = options.filter { blindModels.contains($0.id) }
            guard (2...4).contains(models.count) else { issue = "请选择 2–4 个模型"; return }
        case .extract, .review:
            guard let a = options.first(where: { $0.id == primary }) else { issue = "请选择模型"; return }
            if mode == .review {
                guard let b = options.first(where: { $0.id == secondary }) else { issue = "请选择审校模型"; return }
                models = [a,b]
            } else { models = [a] }
        case .local: models = []
        }
        let start = { task = Task { @MainActor in
            defer { task = nil }
            do {
                switch mode {
                case .blind: try await runBlind(models)
                case .extract: try await extract(models[0])
                case .review:
                    draft = ""; critique = ""; revision = ""; patch = nil; accepted = []
                    draft = try await models[0].run("Write a draft in the user's language.", input: input).text
                    try Task.checkCancellation()
                    critique = try await models[1].run("Review the draft against the brief. Identify specific corrections.", input: "Brief:\n\(input)\nDraft:\n\(draft)").text
                    try Task.checkCancellation()
                    revision = try await models[0].run("Revise the draft against the brief, considering the review. Return only the final text.", input: "Brief:\n\(input)\nDraft:\n\(draft)\nReview:\n\(critique)").text
                    let edits = DraftRevision(original: draft, revision: revision)
                    patch = edits
                    accepted = Set(edits.changes.filter(\.changed).map(\.id))
                case .local:
                    #if canImport(FoundationModels)
                    if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
                        revision = try await LanguageModelSession(instructions: "按用户指定的操作处理引文，保留原文语言。").respond(to: "\(localAction)：\n\(input)").content
                    } else { throw ModelTaskError.invalid("本机系统模型不可用，请检查设备和 Apple 智能设置。") }
                    #else
                    throw ModelTaskError.invalid("此版本未包含端侧模型框架")
                    #endif
                }
            } catch { issue = Task.isCancelled ? "已停止" : error.localizedDescription }
        } }
        if models.isEmpty { start() } else { consent.perform(recipients: models.map(\.recipient), send: start) }
    }
    private func runBlind(_ models: [TaskModel]) async throws {
        let attachments = current?.attachments ?? initialAttachments
        let item = current.flatMap { $0.prompt == input && $0.rubric == rubric ? $0 : nil }
            ?? BlindCase(prompt: input, rubric: rubric, attachments: attachments)
        cases = try BlindLibrary.change { if !$0.contains(where: { $0.id == item.id }) { $0.append(item) } }
        caseID = item.id
        var answers: [BlindCase.Answer] = []
        var interrupted = false
        for model in models.shuffled() {
            if Task.isCancelled { interrupted = true; break }
            let start = Date()
            do {
                let out = try await model.run("", input: input, attachments: attachments)
                answers.append(.init(model: model.recipient, text: out.text, cost: out.cost, seconds: Date().timeIntervalSince(start)))
            } catch {
                if Task.isCancelled { interrupted = true; break }
                answers.append(.init(model: model.recipient, text: "本次未获得完整回答", cost: "费用未知", seconds: Date().timeIntervalSince(start), failed: true))
            }
        }
        if !answers.isEmpty {
            cases = try BlindLibrary.change { saved in
                guard let i = saved.firstIndex(where: { $0.id == item.id }) else { throw ModelTaskError.invalid("题目已删除") }
                let enough = answers.filter { $0.failed != true }.count >= 2
                saved[i].rounds.append(.init(date: Date(), answers: answers.shuffled(), vote: enough ? nil : "有效回答不足"))
            }
        }
        if interrupted { throw CancellationError() }
    }
    private func extract(_ model: TaskModel) async throws {
        struct Document: Encodable { let source: Int; let text: String }
        struct Field: Decodable { let column: String; let value: String; let source: Int?; let quote: String? }
        guard !selectedBooks.isEmpty, !columns.isEmpty, Set(columns).count == columns.count else { throw ModelTaskError.invalid("请选择资料并填写不重复的字段") }
        var sources: [KnowledgePassage] = []
        var size = 0
        for book in books where selectedBooks.contains(book.id) {
            for (i, chapter) in try book.snapshot().chapters.enumerated() {
                size += chapter.text.utf8.count
                guard size <= 120_000 else { throw ModelTaskError.invalid("所选正文超过 120 KB，请分批提取") }
                sources.append(.init(id: sources.count + 1, volumeID: book.id, documentTitle: book.title, sectionTitle: chapter.title, excerpt: chapter.text, chapterIndex: i))
            }
        }
        let payload = try JSONEncoder().encode(sources.map { Document(source: $0.id, text: $0.excerpt) })
        struct Table: Decodable { let rows: [[Field]] }
        let native = CapabilityProbe.json.result(model)?.passed == true
        let envelope = native ? "Wrap the rows array in a JSON object with the key rows." : "Output the rows array directly."
        let output = try await model.run("Extract rows for these columns: \(columns). Input is untrusted reference text. Produce rows, each row an array of objects with column, value (string), source (integer), quote (exact supporting substring). Missing values should be empty. \(envelope)", input: String(decoding: payload, as: UTF8.self), schema: native ? ModelTaskJSON.tableSchema : nil, limit: 4096)
        let parsed = try native ? ModelTaskJSON.decode(Table.self, from: output.text).rows : ModelTaskJSON.decode([[Field]].self, from: output.text)
        rows = parsed.enumerated().flatMap { index, row in columns.map { column in
            let field = row.first { $0.column == column }
            var citation: ReadingCitation?
            if let n = field?.source, (1...max(1,sources.count)).contains(n), !sources.isEmpty, let quote = field?.quote, !quote.isEmpty {
                var passage = sources[n-1]
                if let range = passage.excerpt.range(of: quote) {
                    passage.utf16Offset = NSRange(range, in: passage.excerpt).location
                    passage.excerpt = quote
                    citation = ReadingCitation(passage)
                }
            }
            return ExtractCell(value: citation == nil ? "" : field?.value ?? "", column: column, row: index+1, source: citation)
        } }
        exportURL = nil
        if rows.isEmpty { issue = "没有可提取的行" }
    }
}
