import SwiftUI
import SwiftData

struct ConversationMessageRoute: Hashable {
    let conversation: Conversation
    let messageID: UUID
}

struct ConversationSearchResults: View {
    let conversations: [Conversation]
    let query: HistorySearchQuery
    let session: HistorySearchSession
    let retry: () -> Void
    var onSelectConversation: ((Conversation) -> Void)? = nil
    var onSelectRoute: ((ConversationMessageRoute) -> Void)? = nil
    var onSelectBookHit: ((BookSearchHit) -> Void)? = nil
    var onSelectFlashcardHit: ((FlashcardSearchHit) -> Void)? = nil

    var body: some View {
        if session.completed != query {
            ProgressView("正在搜索…")
        } else if let error = session.error {
            Text(verbatim: error).foregroundStyle(.secondary)
            Button("重试", action: retry)
        } else if !session.hasAnyResults {
            ContentUnavailableView.search(text: query.text)
        } else {
            let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
            ForEach(session.results) { result in
                if let chat = byID[result.id] { rows(for: result, chat: chat) }
            }

            if !session.bookHits.isEmpty {
                Section("书架文档 (\(session.bookHits.count))") {
                    ForEach(session.bookHits) { hit in
                        Button {
                            onSelectBookHit?(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "book.closed.fill")
                                        .foregroundStyle(.teal)
                                    Text(verbatim: hit.bookTitle)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text("·")
                                    Text(verbatim: hit.sectionTitle)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(hit.excerpt.highlighted)
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

            if !session.flashcardHits.isEmpty {
                Section("助学闪卡 (\(session.flashcardHits.count))") {
                    ForEach(session.flashcardHits) { hit in
                        Button {
                            onSelectFlashcardHit?(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "rectangle.stack.fill")
                                        .foregroundStyle(.orange)
                                    Text(verbatim: hit.deckName)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(hit.excerpt.highlighted)
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

    private func rows(for result: ConversationSearchResult, chat: Conversation) -> some View {
        Section(chat.title) {
            if result.matchesDetails {
                if let onSelectConversation {
                    Button {
                        onSelectConversation(chat)
                    } label: {
                        Label("打开对话", systemImage: "bubble.left.and.bubble.right")
                    }
                } else {
                    NavigationLink(value: chat) {
                        Label("打开对话", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            ForEach(result.hits) { hit in
                let route = ConversationMessageRoute(conversation: chat, messageID: hit.id)
                let rowLabel = VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(hit.speaker)
                        if let fieldBadge = hit.matchedField.badgeLabel {
                            Text(fieldBadge)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                        if hit.isOtherBranch { Label("其他分支", systemImage: "arrow.triangle.branch") }
                        Spacer()
                        Text(hit.createdAt, format: .dateTime.month().day())
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(hit.excerpt.highlighted)
                        .font(.subheadline)
                        .lineLimit(3)
                }
                if let onSelectRoute {
                    Button {
                        onSelectRoute(route)
                    } label: {
                        rowLabel
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: route) {
                        rowLabel
                    }
                }
            }
        }
    }
}

extension SearchExcerpt {
    var highlighted: AttributedString {
        if highlightTerms.count <= 1 {
            guard !match.isEmpty else { return AttributedString(fullSnippet) }
            var keyword = AttributedString(match)
            keyword.inlinePresentationIntent = .stronglyEmphasized
            keyword.backgroundColor = Color.accentColor.opacity(0.2)
            return AttributedString(before) + keyword + AttributedString(after)
        }
        let full = fullSnippet
        var result = AttributedString(full)
        let sortedTerms = highlightTerms.sorted { $0.count > $1.count }
        for term in sortedTerms where !term.isEmpty {
            var cursor = full.startIndex
            while cursor < full.endIndex,
                  let range = full.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<full.endIndex) {
                if let attrRange = Range(range, in: result) {
                    result[attrRange].inlinePresentationIntent = .stronglyEmphasized
                    result[attrRange].backgroundColor = Color.accentColor.opacity(0.2)
                }
                cursor = range.upperBound
            }
        }
        return result
    }
}

struct BookSearchHitReaderSheet: View {
    let hit: BookSearchHit
    @Environment(\.dismiss) private var dismiss
    @State private var readingRequest: ReadingRequest?
    @State private var readingPlace = BookReadingPlace()

    var body: some View {
        NavigationStack {
            BookOriginalView(
                volumeID: hit.volumeID,
                throughChapter: nil,
                request: $readingRequest,
                place: $readingPlace,
                openShelf: nil,
                quote: { _ in }
            )
            .navigationTitle(hit.bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                let citation = ReadingCitation(
                    KnowledgePassage(
                        id: 1,
                        volumeID: hit.volumeID,
                        documentTitle: hit.bookTitle,
                        sectionTitle: hit.sectionTitle,
                        excerpt: hit.excerpt.fullSnippet,
                        chapterIndex: hit.chapterIndex,
                        utf16Offset: hit.utf16Offset
                    )
                )
                readingRequest = ReadingRequest(chapter: hit.chapterIndex, citation: citation)
            }
        }
    }
}

struct ConversationSearchDestination: View {
    let route: ConversationMessageRoute
    let onOpenConversation: (Conversation) -> Void
    @Environment(\.modelContext) private var context
    @State private var switchError: String?
    @State private var enteredChat = false

    var body: some View {
        let chat = route.conversation
        if enteredChat || ConversationTree.activeMessages(in: chat).contains(where: { $0.id == route.messageID }) {
            ChatDetailView(conversation: chat, initialMessageID: route.messageID, onOpenConversation: onOpenConversation)
                .onAppear { enteredChat = true }
        } else if let target = chat.messages.first(where: { $0.id == route.messageID }) {
            let path = ConversationTree.activeMessages(in: chat, endingAt: target.id)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(path) { message in
                            MessageRowView(message: message, blindLabel: ArenaSynthesis.blindSpeakerLabel(
                                for: message, in: path, blindArenaMode: chat.assistanceSettings.blindArenaMode))
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .task(id: target.id) { proxy.scrollTo(target.id, anchor: .top) }
            }
            .navigationTitle("其他分支")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button("在此分支继续") {
                    let previous = chat.activeLeafMessageID
                    ConversationTree.switchBranch(to: target, in: chat)
                    do { try context.save() } catch {
                        chat.activeLeafMessageID = previous
                        switchError = error.localizedDescription
                    }
                }
                .disabled(ChatEngine.shared.isGenerating(in: chat.id))
                .buttonStyle(.borderedProminent)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .alert("无法更新对话记录", isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(switchError ?? "") }
        } else {
            ContentUnavailableView("未找到匹配消息", systemImage: "magnifyingglass")
        }
    }
}
