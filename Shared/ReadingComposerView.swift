import SwiftUI

struct ReadingComposerView: View {
    @State var input: ReadingInput
    let models: [SharedModelEntry]
    let connection: (SharedModelEntry) throws -> SharedConnection
    let persist: (ExternalRunReceipt) throws -> Void
    let close: (UUID?) -> Void

    @State private var selection = ""
    @State private var didInitialize = false
    @State private var consent = AIConsentGate()
    @State private var action: ReadingAction = .summarize
    @State private var language = String(localized: "简体中文")
    @State private var customQuestion = ""
    @State private var urlText = ""
    @State private var isReading = false
    @State private var error: String?
    @State private var readTask: Task<Void, Never>?
    @State private var session = ReadingSession()

    var body: some View {
        NavigationStack {
            Form {
                if models.isEmpty {
                    Text("没有可用模型，请先在「夜奔」的服务商设置中启用模型与系统分享。")
                        .foregroundStyle(.secondary)
                } else {
                    Section("处理方式") {
                        Picker("操作", selection: $action) {
                            ForEach(ReadingAction.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if action == .translate { TextField("目标语言", text: $language) }
                        if action == .ask { TextField("输入你的指令或问题…", text: $customQuestion, axis: .vertical).lineLimit(1...4) }
                        Picker("模型", selection: $selection) {
                            ForEach(models) { model in
                                Text("\(model.target.modelDisplayName) · \(model.target.providerName)").tag(model.id)
                            }
                        }
                    }.disabled(session.isRunning || session.receipt != nil)
                }

                if session.receipt == nil {
                    Section {
                        TextField("https://example.com/article", text: $urlText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button {
                            readPage()
                        } label: {
                            if isReading { HStack { ProgressView(); Text("正在读取网页…") } }
                            else { Label("读取网页正文", systemImage: "doc.text.magnifyingglass") }
                        }.disabled(isReading || urlText.isEmpty)
                    } header: { Text("网页链接（可选）") } footer: {
                        Text("读取公开网页，不使用浏览器登录状态。读取失败时可直接粘贴或分享正文。")
                    }

                    Section("发送内容预览") {
                        if !input.attachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(input.attachments) { att in
                                        if let uiImg = att.cachedImage {
                                            Image(uiImage: uiImg)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 72, height: 72)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        }
                                    }
                                }
                            }
                        }
                        if !input.title.isEmpty { Text(input.title).font(.headline) }
                        TextEditor(text: $input.text).frame(height: input.attachments.isEmpty ? 180 : 100)
                            .accessibilityLabel("发送内容预览")
                        Text("\(input.text.count) 个字符")
                            .font(.caption).foregroundStyle(.secondary)
                        if input.isTruncated || input.text.count > URLReader.maximumCharacters {
                            Text("内容较长，仅发送前 60000 个字符。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.disabled(isReading)
                    Section {
                        Button("开始处理") { start() }
                            .disabled(isReading || models.isEmpty || (input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && input.attachments.isEmpty))
                    } footer: {
                        Text("预览中的内容将发送给所选服务商，可能产生 API 费用。结果与用量保存在「夜奔」；模型总结不等于事实核查。")
                    }
                }

                if let receipt = session.receipt {
                    Section("处理结果") {
                        if session.isRunning { HStack { ProgressView(); Text("正在生成…") } }
                        if !receipt.answer.isEmpty { Text(receipt.answer).textSelection(.enabled) }
                        if let reason = receipt.finishReason.flatMap(LLMFinishReason.init(rawValue:)) {
                            Text(reason.userNotice).foregroundStyle(.orange)
                        }
                        if let error = receipt.error { Text(error).foregroundStyle(.orange) }
                        if session.isRunning { Button("停止生成", role: .destructive) { session.cancel() } }
                        else {
                            if !receipt.answer.isEmpty { ShareLink(item: receipt.answer) { Label("分享结果", systemImage: "square.and.arrow.up") } }
                            Text("关闭后可在「夜奔」的对话和用量中查看。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let error = session.saveError {
                    Section { Text(error).foregroundStyle(.red); Button("重试保存") { session.retrySave() } }
                }
            }
            .navigationTitle("分享与精读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.isRunning ? String(localized: "停止并关闭") : String(localized: "完成")) {
                        readTask?.cancel()
                        Task {
                            session.cancel()
                            await session.wait()
                            guard session.saveError == nil else { return }
                            close(session.receipt?.id)
                        }
                    }
                }
            }
            .aiConsentSheet(consent)
            .onAppear {
                guard !didInitialize else { return }
                didInitialize = true
                if !input.attachments.isEmpty {
                    selection = models.first(where: { $0.spec.supportsVision })?.id ?? models.first?.id ?? ""
                    action = .ask
                } else {
                    selection = models.first?.id ?? ""
                }
                urlText = input.url?.absoluteString ?? ""
            }
            .onDisappear { readTask?.cancel(); session.cancel() }
            .interactiveDismissDisabled(session.isRunning || session.saveError != nil)
        }
    }

    private func readPage() {
        let enteredURL = urlText
        guard let url = URL(string: enteredURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = URLReaderError.unsafeURL.localizedDescription; return
        }
        isReading = true
        error = nil
        readTask = Task {
            defer { isReading = false }
            do {
                let page = try await URLReader.read(url)
                try Task.checkCancellation()
                guard urlText == enteredURL else { return }
                input = ReadingInput(text: page.text, url: page.url, title: page.title, isTruncated: page.isTruncated)
                urlText = page.url.absoluteString
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func start() {
        guard let model = models.first(where: { $0.id == selection }) else { return }
        if !input.attachments.isEmpty && !model.spec.supportsVision {
            error = String(localized: "所选模型未启用识图能力，请选择支持图片的模型。")
            return
        }
        do {
            let enteredURL = urlText
            let selectedAction = action
            let selectedLanguage = language
            let question = customQuestion
            var source = input
            source.url = ReadingInput.sharedSourceURL(enteredURL)
            let prompt = try source.prompt(action: selectedAction, language: selectedLanguage.isEmpty ? String(localized: "简体中文") : selectedLanguage, question: question)
            let display = source.displayPrompt(action: selectedAction, language: selectedLanguage, question: question)
            let fallbackTitle = source.text.isEmpty ? String(localized: "分析图片") : String(source.text.prefix(36))
            let title = selectedAction.title + " · " + (source.title.isEmpty ? fallbackTitle : source.title)
            let attachments = source.attachments
            let resolved = try connection(model)
            let recipient = AppCompliance.recipient(provider: model.target.providerName, model: model.target.modelDisplayName,
                                                     baseURL: resolved.baseURL)
            consent.perform(recipients: [recipient], isCurrent: {
                urlText == enteredURL && selection == model.id && (try? connection(model)) == resolved
            }) {
                send(model, prompt: prompt, attachments: attachments, title: title, display: display, expected: resolved)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func send(_ model: SharedModelEntry, prompt: String, attachments: [MessageAttachment],
                      title: String, display: String, expected: SharedConnection) {
        do {
            let current = try connection(model)
            guard current == expected else {
                throw LLMError.apiError(String(localized: "连接配置已更改，请重新验证。"))
            }
            var request = try current.request(for: model, text: prompt, systemPrompt: ReadingInput.systemPrompt, attachments: attachments)
            request.validateBeforeSending = {
                guard try connection(model) == expected else { throw AppCompliance.RequestChanged() }
            }
            session.start(entry: model, request: request, title: title, displayPrompt: display, persist: persist)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
