import SwiftUI
import UniformTypeIdentifiers

struct PersonaEditorView: View {
    @Binding var member: GroupMember
    @State private var importing = false
    @State private var editing: PersonaMaterial?
    @State private var kind: PersonaFeed.Kind = .blog
    @State private var address = ""
    @State private var error: String?
    @State private var token = ""
    @State private var hasToken = false

    private var persona: GroupPersona { member.persona ?? GroupPersona() }

    var body: some View {
        Form {
            Section {
                ForEach(persona.materials) { material in
                    Button { editing = material } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: material.title).foregroundStyle(.primary)
                            Text(verbatim: material.text).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in update { $0.materials.remove(atOffsets: offsets) } }
                Button { importing = true } label: { Label("导入参考资料", systemImage: "doc.badge.plus") }
                    .disabled(persona.materials.count >= PersonaMaterial.maximumCount)
            } header: {
                Text("发言参考")
            } footer: {
                Text("最多 6 份。发言时，相关片段会发送给这位成员绑定的模型。群内发言标注为 AI 模拟，资料随对话备份导出。")
            }
            Section {
                ForEach(persona.feeds) { feed in
                    Toggle(isOn: Binding(get: { feed.enabled }, set: { enabled in
                        update { value in
                            if let i = value.feeds.firstIndex(where: { $0.id == feed.id }) { value.feeds[i].enabled = enabled }
                        }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: feed.displayName).lineLimit(2)
                            if let failure = feed.lastError {
                                Text(verbatim: failure).font(.caption).foregroundStyle(.orange)
                            } else if let date = feed.lastChecked {
                                Text("上次检查 \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("等待首次检查").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in update { $0.feeds.remove(atOffsets: offsets) } }
                Picker("订阅类型", selection: $kind) {
                    Text("博客").tag(PersonaFeed.Kind.blog)
                    Text(verbatim: "X / Twitter").tag(PersonaFeed.Kind.x)
                }.pickerStyle(.segmented)
                TextField(kind == .blog ? String(localized: "博客主页或 RSS / Atom 地址") : String(localized: "X 用户名或个人主页"), text: $address)
                    .keyboardType(kind == .blog ? .URL : .default).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button { addFeed() } label: { Label("添加订阅", systemImage: "plus") }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || persona.feeds.count >= 4)
            } header: {
                Text("自动分享到本群")
            } footer: {
                Text("首次检查只记录现有内容。之后的新动态会附原文链接发进本群。iOS 决定后台检查时间，也可从群聊菜单手动检查。")
            }
            if kind == .x || persona.feeds.contains(where: { $0.kind == .x }) {
                Section {
                    SecureField("X API Bearer Token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(hasToken ? String(localized: "替换读取凭据") : String(localized: "保存读取凭据")) { saveToken(token) }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasToken { Button("移除读取凭据", role: .destructive) { saveToken("") } }
                } header: {
                    Text("X 读取权限")
                } footer: {
                    Text("使用你自己的 X API 读取额度。凭据立即保存到本机钥匙串，供此设备上的 X 订阅共用。")
                }
            }
        }
        .navigationTitle("人物资料与动态")
        .onAppear { hasToken = !KeychainService.shared.loadSecret(account: PersonaFeedReader.xTokenAccount).isEmpty }
        .sheet(isPresented: $importing) { PersonaMaterialSheet(speaker: member.name, onSave: store) }
        .sheet(item: $editing) { PersonaMaterialSheet(speaker: member.name, material: $0, onSave: store) }
        .alert("无法更新人物设置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(verbatim: error ?? "") }
    }

    private func update(_ change: (inout GroupPersona) -> Void) {
        var value = persona
        change(&value)
        member.persona = value.isEmpty ? nil : value
    }

    private func store(_ material: PersonaMaterial) {
        update { value in
            if let i = value.materials.firstIndex(where: { $0.id == material.id }) { value.materials[i] = material }
            else if value.materials.count < PersonaMaterial.maximumCount { value.materials.append(material) }
        }
    }

    private func addFeed() {
        do {
            let feed = try PersonaFeedReader.source(address, kind: kind)
            guard !persona.feeds.contains(where: { $0.kind == kind && $0.address == feed.address }) else {
                error = String(localized: "已添加这个订阅。"); return
            }
            update { $0.feeds.append(feed) }
            address = ""
        } catch { self.error = error.localizedDescription }
    }

    private func saveToken(_ value: String) {
        guard KeychainService.shared.saveSecret(value, account: PersonaFeedReader.xTokenAccount) else {
            error = PersonaError.credentialSave.localizedDescription; return
        }
        hasToken = !value.isEmpty
        token = ""
    }
}

private struct PersonaMaterialSheet: View {
    enum Source { case writing, chat, article }
    @Environment(\.dismiss) private var dismiss
    let material: PersonaMaterial?
    let onSave: (PersonaMaterial) -> Void
    @State private var source: Source = .writing
    @State private var speaker: String
    @State private var articles: [PersonaFeedItem] = []
    @State private var raw = ""
    @State private var address = ""
    @State private var title: String
    @State private var excerpt: String
    @State private var url: URL?
    @State private var preview: Bool
    @State private var truncated = false
    @State private var pickingFile = false
    @State private var busy = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    init(speaker: String, material: PersonaMaterial? = nil, onSave: @escaping (PersonaMaterial) -> Void) {
        self.material = material
        self.onSave = onSave
        _speaker = State(initialValue: speaker)
        _title = State(initialValue: material?.title ?? "")
        _excerpt = State(initialValue: material?.text ?? "")
        _url = State(initialValue: material?.url)
        _preview = State(initialValue: material != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if preview {
                    Section("资料名称") { TextField("资料名称", text: $title) }
                    Section {
                        TextEditor(text: $excerpt).frame(minHeight: 175)
                            .accessibilityLabel("参考片段")
                        Text("\(excerpt.count) / 4000").font(.caption).foregroundStyle(.secondary)
                        if let url, (try? URLReader.validate(url)) != nil { Link(destination: url) { Text(verbatim: url.absoluteString).font(.caption) } }
                    } header: { Text("参考片段") } footer: {
                        if truncated { Text("内容较长，已选取前 4,000 个字符。可在保存前编辑。") }
                    }
                    if material == nil { Button("重新选取内容") { preview = false } }
                } else {
                    Section {
                        Picker("资料来源", selection: $source) {
                            Text("文字").tag(Source.writing)
                            Text("聊天记录").tag(Source.chat)
                            Text("博客文章").tag(Source.article)
                        }.pickerStyle(.segmented)
                    }
                    if source == .article {
                        Section("博客文章") {
                            TextField("文章或博客主页的 HTTPS 地址", text: $address).keyboardType(.URL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("从博客订阅挑选文章") {
                                perform {
                                    let source = try PersonaFeedReader.source(address, kind: .blog)
                                    guard let url = URL(string: source.address) else { throw URLReaderError.unsafeURL }
                                    let found = try await PersonaFeedReader().blogEntries(at: url)
                                    try Task.checkCancellation()
                                    articles = Array(found.items.prefix(20))
                                    if articles.isEmpty { error = String(localized: "订阅里还没有可选的文章。") }
                                }
                            }.disabled(address.isEmpty)
                            ForEach(articles, id: \.id) { article in
                                Button { preparePreview(article: article) } label: {
                                    Label(article.title, systemImage: "doc.plaintext")
                                }
                            }
                        }
                    } else {
                        if source == .chat {
                            Section { TextField("发言人名字", text: $speaker) } footer: {
                                Text("只提取这位发言人的消息。支持「姓名：内容」或带发言人和正文的 JSON 记录。")
                            }
                        }
                        Section {
                            TextEditor(text: $raw).frame(minHeight: 132).accessibilityLabel("待导入文字")
                            Button { pickingFile = true } label: { Label("从文件选择", systemImage: "folder") }
                        } header: { Text("粘贴文字或选择文件") } footer: { Text("支持 TXT、Markdown 和 JSON，文件最大 2 MB。") }
                    }
                }
                if let error { Text(verbatim: error).font(.footnote).foregroundStyle(.red) }
                if busy { ProgressView() }
            }
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(preview ? String(localized: "核对参考资料") : String(localized: "导入参考资料"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if !preview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("预览") { preparePreview() }
                            .accessibilityLabel("预览提取结果")
                            .disabled(busy || (source == .article ? address.isEmpty : raw.isEmpty))
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            onSave(PersonaMaterial(id: material?.id ?? UUID(), title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
                                                   text: excerpt.trimmingCharacters(in: .whitespacesAndNewlines), url: url))
                            dismiss()
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || excerpt.count > PersonaMaterial.maximumCharacters)
                    }
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.plainText, .text, .json, UTType(filenameExtension: "md") ?? .plainText]) { result in
                do {
                    let file = try result.get()
                    perform {
                        let value = try await Task.detached(priority: .userInitiated) { try PersonaMaterials.readFile(file) }.value
                        try Task.checkCancellation()
                        raw = value
                        title = file.deletingPathExtension().lastPathComponent
                    }
                } catch { self.error = error.localizedDescription }
            }
            .onChange(of: address) { _, _ in articles = [] }
            .onDisappear { work?.cancel() }
        }
    }

    private func preparePreview(article: PersonaFeedItem? = nil) {
        perform {
            let value: String
            var suggested: String
            var origin: URL?
            if source == .article {
                guard let link = article?.url ?? URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw URLReaderError.unsafeURL }
                let page = try await URLReader.read(link)
                value = page.text
                suggested = article?.title ?? page.title
                origin = page.url
            } else {
                guard raw.utf8.count <= URLReader.maximumBytes else { throw PersonaError.tooLarge }
                let (input, name, isChat) = (raw, speaker, source == .chat)
                value = try await Task.detached(priority: .userInitiated) {
                    try isChat ? PersonaMaterials.chatText(input, speaker: name) : input.trimmingCharacters(in: .whitespacesAndNewlines)
                }.value
                suggested = source == .chat ? String(localized: "\(speaker)的聊天记录") : String(value.prefix(24))
            }
            try Task.checkCancellation()
            guard !value.isEmpty else { throw PersonaError.empty }
            if suggested.isEmpty { suggested = origin?.host ?? String(localized: "参考片段") }
            if title.isEmpty || source == .article { title = suggested }
            url = origin
            excerpt = String(value.prefix(PersonaMaterial.maximumCharacters))
            truncated = value.count > PersonaMaterial.maximumCharacters
            preview = true
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        busy = true
        work = Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
