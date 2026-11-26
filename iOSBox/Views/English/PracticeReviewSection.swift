import SwiftData
import SwiftUI

struct PracticeReviewSection: View {
    let chat: Conversation
    var reviewOnOpen = false
    @Query private var providers: [ProviderConfig]
    @State private var consent = AIConsentGate()
    @State private var selectedModelID: String?
    @State private var didAutoReview = false
    @State private var reviewTask: Task<Void, Never>?
    @State private var failure: String?

    private var provider: ProviderConfig? {
        providers.first { $0.id == chat.assistanceSettings.voicePractice?.providerID && LiveVoiceSession.isOpenAI($0) && LiveVoiceSession.supports($0) }
    }

    private var options: [ModelSpec] { provider.map(LanguagePractice.reviewModels) ?? [] }

    private func reviewModel(_ lesson: PracticeLesson) -> TaskModel? {
        guard let provider, let spec = options.first(where: { $0.id == (selectedModelID ?? lesson.reviewModelID) }) else { return nil }
        return TaskModel(provider: provider, spec: spec)
    }

    var body: some View {
        if let lesson = chat.assistanceSettings.voicePractice {
            Section("本次练习") {
                Text(lesson.profile.trimmedScene).font(.headline)
                Text("\(lesson.profile.languageName) · \(lesson.profile.level.rawValue.uppercased())")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink("查看练习原对话") { ChatDetailView(conversation: chat) }
                if lesson.incompleteTranscript == true || lesson.pendingTranscription == true {
                    Text("部分语音未完成转写，复盘只使用已保存的发言。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            PracticeUsageSection(chat: chat)
            if !lesson.targets.isEmpty, !LanguagePractice.reviewTurns(in: chat).isEmpty {
                Section("这次能自己说出来吗？") {
                    ForEach(lesson.targets) { target in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(target.expression)
                            if let recalled = target.recalled {
                                Text(recalled ? "已延后复习" : "下次再练").font(.caption).foregroundStyle(.secondary)
                            } else {
                                HStack {
                                    Button("说出来了") { rate(target, recalled: true) }
                                    Button("还要练") { rate(target, recalled: false) }
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            Section("课后复盘") {
                if let failure { Text(failure).foregroundStyle(.secondary).accessibilityIdentifier("practice.reviewError") }
                if lesson.reviewed {
                    let sourced = LanguagePractice.cards(in: chat)
                    if sourced.isEmpty { Text("本次没有需要加入复习的表达。") }
                    ForEach(sourced) { card in cardRow(card) }
                } else if lesson.isResumable == true {
                    Text("结束本次练习后即可复盘。")
                } else if LanguagePractice.reviewTurns(in: chat).isEmpty {
                    Text("本次没有可复盘的发言。")
                } else if reviewTask != nil {
                    ProgressView("正在核对原话…")
                } else {
                    if !options.isEmpty {
                        let model = reviewModel(lesson)
                        Picker("复盘文本模型", selection: Binding(get: { model?.spec.id ?? "" }, set: { selectedModelID = $0 })) {
                            if model == nil { Text("选择模型").tag("") }
                            ForEach(options) { Text($0.displayName).tag($0.id) }
                        }
                        Button("生成练习复盘") { if let model { request(model) } }
                            .disabled(model == nil).accessibilityIdentifier("practice.review")
                    } else { Text("在本次练习的 OpenAI 账号中启用文本模型，即可生成复盘。") }
                }
            }
            .aiConsentSheet(consent)
            .task {
                guard reviewOnOpen, !didAutoReview else { return }
                didAutoReview = true
                if !lesson.reviewed, lesson.isResumable != true, !LanguagePractice.reviewTurns(in: chat).isEmpty,
                   let model = reviewModel(lesson) { request(model) }
            }
            .onDisappear { reviewTask?.cancel() }
        }
    }

    private func cardRow(_ card: PracticeCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.expression).font(.headline)
            NavigationLink {
                ConversationSearchDestination(route: ConversationMessageRoute(conversation: chat, messageID: card.messageID)) {
                    SystemEntryRouter.shared.conversationID = $0.id
                }
            } label: {
                Label(card.quote, systemImage: "quote.bubble").foregroundStyle(.secondary)
            }.accessibilityIdentifier("practice.source")
            Text(card.note).font(.subheadline)
            Button(card.due == nil ? "加入下次练习" : "移出复习") {
                do {
                    try LanguagePractice.setScheduled(card.due == nil, cardID: card.id, in: chat)
                    failure = nil
                } catch { failure = error.localizedDescription }
            }.buttonStyle(.bordered).accessibilityIdentifier("practice.schedule")
        }.padding(.vertical, 4)
    }

    private func rate(_ target: PracticeTarget, recalled: Bool) {
        do {
            try LanguagePractice.rate(target, recalled: recalled, in: chat)
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    private func request(_ model: TaskModel) {
        guard reviewTask == nil else { return }
        consent.perform(recipients: [model.recipient], isCurrent: { (try? model.recipientCheck()) != nil }) {
            failure = nil
            reviewTask = Task {
                defer { reviewTask = nil }
                do { try await LanguagePractice.review(chat, using: model, helpLanguage: Locale.preferredLanguages.first ?? "zh-Hans") }
                catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
        }
    }
}
