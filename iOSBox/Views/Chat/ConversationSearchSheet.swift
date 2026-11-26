import SwiftUI
import SwiftData

struct ConversationSearchSheet: View {
    let conversation: Conversation
    let messages: [ChatMessage]
    let anchor: UUID?
    @State private var showsDirectory = false
    let onSelectMessage: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var onlyBookmarked = false

    @Environment(\.modelContext) private var context
    @State private var revision = 0
    @State private var completed: Request?
    @State private var matches: [MessageSearchText.Match] = []

    private struct Request: Equatable {
        let query: String
        let bookmarksOnly: Bool
        let revision: Int
        let ids: [UUID]
    }

    private var request: Request {
        Request(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                bookmarksOnly: onlyBookmarked, revision: revision, ids: messages.map(\.id))
    }

    var body: some View {
        if showsDirectory {
            QuestionDirectorySheet(conversation: conversation, jump: onSelectMessage)
        } else { findMessages }
    }

    private var findMessages: some View {
        NavigationStack {
            List {
                let current = request
                let adjacent = Self.neighboringQuestions(in: messages, at: anchor)
                Section("按提问跳转") {
                    Button { showsDirectory = true } label: { Label("问题目录", systemImage: "list.number") }
                    HStack {
                        questionButton("上一问", icon: "chevron.backward", target: adjacent.previous, key: .leftArrow)
                        Spacer()
                        questionButton("下一问", icon: "chevron.forward", target: adjacent.next, key: .rightArrow)
                    }
                    .buttonStyle(.borderless)
                }
                Section {
                    Toggle("仅显示已收藏消息", isOn: $onlyBookmarked)
                }

                if completed != current && (!current.query.isEmpty || current.bookmarksOnly) {
                    ProgressView("正在搜索…")
                } else if matches.isEmpty || completed != current {
                    ContentUnavailableView(
                        onlyBookmarked && query.isEmpty ? String(localized: "暂无收藏消息") : String(localized: "未找到匹配消息"),
                        systemImage: onlyBookmarked ? "bookmark" : "magnifyingglass",
                        description: Text(onlyBookmarked && query.isEmpty
                                          ? String(localized: "长按或点击消息收藏按钮即可将重要回答加入收藏。")
                                          : String(localized: "尝试更换关键词，或关闭收藏筛选。"))
                    )
                } else {
                    Section("匹配结果 (\(matches.count))") {
                        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                        ForEach(matches) { match in
                            if let msg = byID[match.id] {
                                Button {
                                    onSelectMessage(msg.id)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Text(msg.role == .user
                                                 ? String(localized: "提问")
                                                 : ArenaSynthesis.visibleSpeakerName(for: msg))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(msg.role == .user ? Color.accentColor : .secondary)
                                            if msg.assistanceMetadata.isBookmarked {
                                                Image(systemName: "bookmark.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(DS.StatusText.warning)
                                            }
                                            Spacer()
                                            Text(msg.createdAt, format: .dateTime.month().day().hour().minute())
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(match.excerpt?.highlighted ?? AttributedString(msg.content.isEmpty ? msg.attachments.map(\.fileName).joined(separator: ", ") : msg.content))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .task(id: request) {
                let current = request
                do {
                    var found: [MessageSearchText.Match] = []
                    if !current.query.isEmpty || current.bookmarksOnly {
                        if !current.query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                        found = try await MessageSearchText.matches(in: messages.map(MessageSearchText.init),
                                                                    query: current.query, bookmarksOnly: current.bookmarksOnly)
                    }
                    try Task.checkCancellation()
                    matches = found
                    completed = current
                } catch is CancellationError { }
                catch { assertionFailure(String(describing: error)) }
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: context)) { _ in revision += 1 }
            .onChange(of: messages.last?.content) { revision += 1 }
            .searchable(text: $query, prompt: "在当前会话中搜索")
            .navigationTitle("会话内查找与收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
    private func questionButton(_ title: LocalizedStringKey, icon: String, target: UUID?, key: KeyEquivalent) -> some View {
        Button {
            if let target { onSelectMessage(target); dismiss() }
        } label: { Label(title, systemImage: icon) }
            .keyboardShortcut(key, modifiers: [.command, .option])
            .accessibilityLabel(Text(title))
            .disabled(target == nil)
    }

    static func neighboringQuestions(in messages: [ChatMessage], at anchor: UUID?) -> (previous: UUID?, next: UUID?) {
        let index = messages.firstIndex { $0.id == anchor } ?? messages.endIndex
        func question(_ item: ChatMessage) -> Bool { item.role == .user && !item.assistanceMetadata.isContextDivider }
        let previous = messages[..<index].last(where: question)?.id
        let next = index < messages.endIndex ? messages[(index + 1)...].first(where: question)?.id : nil
        return (previous, next)
    }

}
