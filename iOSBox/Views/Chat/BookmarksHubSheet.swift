import SwiftUI
import SwiftData
import UIKit

struct BookmarkedMessageEntry: Identifiable, Hashable {
    let id: UUID
    let conversationID: UUID
    let conversationTitle: String
    let folderTag: String?
    let speaker: String
    let content: String
    let createdAt: Date
}

enum BookmarksHubFilter {
    static func availableTags(from entries: [BookmarkedMessageEntry]) -> [String] {
        let tags = Set(entries.compactMap { entry -> String? in
            let cleaned = entry.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return cleaned.isEmpty ? nil : cleaned
        })
        return tags.sorted()
    }

    static func filter(
        _ entries: [BookmarkedMessageEntry],
        query: String,
        tag: String?
    ) -> [BookmarkedMessageEntry] {
        let cleanTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return entries
            .filter { entry in
                if let cleanTag, !cleanTag.isEmpty {
                    let entryTag = entry.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if entryTag != cleanTag {
                        return false
                    }
                }
                if !cleanQuery.isEmpty {
                    let matchesContent = entry.content.localizedCaseInsensitiveContains(cleanQuery)
                    let matchesTitle = entry.conversationTitle.localizedCaseInsensitiveContains(cleanQuery)
                    let matchesSpeaker = entry.speaker.localizedCaseInsensitiveContains(cleanQuery)
                    let matchesTag = entry.folderTag?.localizedCaseInsensitiveContains(cleanQuery) == true
                    if !matchesContent && !matchesTitle && !matchesSpeaker && !matchesTag {
                        return false
                    }
                }
                return true
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

struct BookmarksHubSheet: View {
    let onJumpToRoute: (ConversationMessageRoute) -> Void
    let onBookmarksChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<ChatMessage> { $0.assistanceMetadataData != nil },
        sort: \ChatMessage.createdAt,
        order: .reverse
    ) private var candidateMessages: [ChatMessage]

    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var copiedMessageID: UUID?
    @State private var exportShareItem: BookmarkSharePayload?
    @State private var exportErrorMessage: String?
    @State private var preferences = AppPreferences.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var bookmarkedMessages: [UUID: ChatMessage] {
        var map: [UUID: ChatMessage] = [:]
        for msg in candidateMessages {
            let meta = msg.assistanceMetadata
            if meta.isBookmarked, !meta.isContextDivider, msg.conversation != nil {
                map[msg.id] = msg
            }
        }
        return map
    }

    private var allEntries: [BookmarkedMessageEntry] {
        candidateMessages.compactMap { msg -> BookmarkedMessageEntry? in
            let meta = msg.assistanceMetadata
            guard meta.isBookmarked, !meta.isContextDivider, let conv = msg.conversation else {
                return nil
            }
            let speaker: String = {
                if msg.role == .user { return String(localized: "我") }
                let display = msg.modelDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !display.isEmpty { return display }
                let provider = msg.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
                return provider.isEmpty ? String(localized: "助手") : provider
            }()
            return BookmarkedMessageEntry(
                id: msg.id,
                conversationID: conv.id,
                conversationTitle: conv.title,
                folderTag: conv.folderTag,
                speaker: speaker,
                content: msg.content,
                createdAt: msg.createdAt
            )
        }
    }

    var body: some View {
        let entries = allEntries
        let tags = BookmarksHubFilter.availableTags(from: entries)
        let filtered = BookmarksHubFilter.filter(entries, query: searchText, tag: selectedTag)
        let messageMap = bookmarkedMessages

        NavigationStack {
            List {
                if !tags.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                tagChip(title: String(localized: "全部"), selected: selectedTag == nil) {
                                    selectedTag = nil
                                }
                                ForEach(tags, id: \.self) { tag in
                                    tagChip(title: tag, selected: selectedTag == tag) {
                                        selectedTag = (selectedTag == tag) ? nil : tag
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    .listRowBackground(Color.clear)
                }

                if filtered.isEmpty {
                    ContentUnavailableView(
                        entries.isEmpty ? "暂无收藏消息" : "没有匹配的收藏内容",
                        systemImage: "bookmark",
                        description: Text(entries.isEmpty
                            ? "长按任意消息或在消息快捷栏点击书签即可跨会话汇总到这里。"
                            : "尝试更换搜索关键词或清除分组标签筛选。")
                    )
                } else {
                    ForEach(filtered) { entry in
                        bookmarkRow(entry: entry, message: messageMap[entry.id])
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索收藏内容、对话或模型")
            .navigationTitle("跨会话收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $exportShareItem) { item in
                BookmarkActivityShareSheet(items: [item.url])
            }
            .alert("无法导出 PDF", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) { exportErrorMessage = nil }
            } message: {
                Text(exportErrorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func bookmarkRow(entry: BookmarkedMessageEntry, message: ChatMessage?) -> some View {
        let preview = PlainTextFormatter.format(entry.content)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: 6) {
                Text(entry.conversationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.readableText)
                    .lineLimit(1)
                if let tag = entry.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                    Text(tag)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.softFill, in: Capsule())
                        .foregroundStyle(theme.readableText)
                }
                Spacer(minLength: 0)
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(entry.speaker)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(preview.isEmpty ? entry.content : preview)
                .font(.subheadline)
                .lineLimit(4)
                .foregroundStyle(.primary)

            HStack(spacing: DS.Spacing.sm) {
                if let conv = message?.conversation, let msg = message {
                    Button {
                        dismiss()
                        onJumpToRoute(ConversationMessageRoute(conversation: conv, messageID: msg.id))
                    } label: {
                        Label("打开对话", systemImage: "arrow.up.right.square")
                    }
                }

                Button {
                    let plain = preview.isEmpty ? entry.content : preview
                    UIPasteboard.general.string = plain
                    copiedMessageID = entry.id
                    preferences.triggerLightHaptic()
                } label: {
                    Label(
                        copiedMessageID == entry.id ? "已复制" : "复制纯文本",
                        systemImage: copiedMessageID == entry.id ? "checkmark" : "doc.on.doc"
                    )
                }

                Button {
                    do {
                        let url = try MessageExportRenderer.writePDFFile(
                            title: entry.conversationTitle,
                            speaker: entry.speaker,
                            date: entry.createdAt,
                            markdown: entry.content
                        )
                        exportShareItem = BookmarkSharePayload(url: url)
                    } catch {
                        exportErrorMessage = error.localizedDescription
                    }
                } label: {
                    Label("导出 PDF", systemImage: "doc.richtext")
                }

                Spacer(minLength: 0)

                if let msg = message {
                    Button(role: .destructive) {
                        var meta = msg.assistanceMetadata
                        meta.isBookmarked = false
                        msg.assistanceMetadata = meta
                        try? modelContext.save()
                        onBookmarksChanged()
                    } label: {
                        Image(systemName: "bookmark.slash")
                    }
                    .accessibilityLabel("取消收藏")
                }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func tagChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? theme.tintColor : DS.Surface.subtle, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct BookmarkSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct BookmarkActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
