import SwiftData
import SwiftUI

/// iPad ⌘K quick switcher across workspace spaces, conversations, bookshelf volumes, and actions.
struct PadCommandPaletteSheet: View {
    let conversations: [Conversation]
    let books: [BookVolume]
    let onSelectSpace: (WorkspaceNavigation.PadSpace) -> Void
    let onSelectConversation: (Conversation) -> Void
    let onOpenBook: (BookVolume) -> Void
    let onCreateNewChat: () -> Void
    let onCreateArenaChat: () -> Void
    let onToggleInspector: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var preferences = AppPreferences.shared
    @FocusState private var searchFocused: Bool

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSpaces: [WorkspaceNavigation.PadSpace] {
        var all: [WorkspaceNavigation.PadSpace] = [.chat, .bookshelf]
        if preferences.showsBookFriends { all.append(.friends) }
        all.append(.workshop)
        if preferences.showsUsageTab { all.append(.usage) }
        all.append(.settings)
        guard !trimmedQuery.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(trimmedQuery) }
    }

    private var filteredConversations: [Conversation] {
        let base = trimmedQuery.isEmpty
            ? Array(conversations.prefix(6))
            : Array(conversations.filter {
                $0.title.localizedStandardContains(trimmedQuery)
                    || ($0.folderTag?.localizedStandardContains(trimmedQuery) ?? false)
            }.prefix(8))
        return base
    }

    private var filteredBooks: [BookVolume] {
        let base = trimmedQuery.isEmpty
            ? Array(books.prefix(4))
            : Array(books.filter {
                $0.title.localizedStandardContains(trimmedQuery)
                    || $0.chapterTitles.contains(where: { $0.localizedStandardContains(trimmedQuery) })
            }.prefix(6))
        return base
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.readableText)
                    TextField("跳转对话、书架、工作空间或命令…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .accessibilityIdentifier("commandPalette.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .background(DS.Surface.card)

                Divider()

                List {
                    if trimmedQuery.isEmpty {
                        Section("快捷操作") {
                            commandRow(title: String(localized: "新对话"), symbol: "square.and.pencil", shortcut: "⌘N") {
                                dismiss()
                                onCreateNewChat()
                            }
                            if preferences.showsArena {
                                commandRow(title: String(localized: "多模型对比"), symbol: "square.split.2x1", shortcut: nil) {
                                    dismiss()
                                    onCreateArenaChat()
                                }
                            }
                            commandRow(title: String(localized: "会话检视器"), symbol: "sidebar.right", shortcut: "⌘⌥I") {
                                dismiss()
                                onToggleInspector()
                            }
                        }
                    }

                    if !filteredSpaces.isEmpty {
                        Section("工作空间") {
                            ForEach(filteredSpaces) { space in
                                commandRow(title: space.title, symbol: space.symbol, shortcut: shortcutHint(for: space)) {
                                    dismiss()
                                    onSelectSpace(space)
                                }
                            }
                        }
                    }

                    if !filteredConversations.isEmpty {
                        Section("最近对话") {
                            ForEach(filteredConversations) { chat in
                                Button {
                                    dismiss()
                                    onSelectConversation(chat)
                                } label: {
                                    HStack(spacing: DS.Spacing.sm) {
                                        AssistantEmojiIcon(emoji: chat.assistantEmoji, font: .subheadline)
                                            .frame(width: 28, height: 28)
                                            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: chat.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            if let tag = chat.folderTag, !tag.isEmpty {
                                                Text(verbatim: tag)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(chat.updatedAt, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(minHeight: DS.TouchTarget.minimum)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !filteredBooks.isEmpty {
                        Section("书架") {
                            ForEach(filteredBooks) { book in
                                Button {
                                    dismiss()
                                    onOpenBook(book)
                                } label: {
                                    HStack(spacing: DS.Spacing.sm) {
                                        DSIconTile(systemImage: "text.book.closed.fill", tint: theme.readableText, size: 28, cornerRadius: DS.Radius.xs)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: book.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("共 \(book.chapterTitles.count) 节")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("继续阅读")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(theme.readableText)
                                    }
                                    .frame(minHeight: DS.TouchTarget.minimum)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if filteredSpaces.isEmpty && filteredConversations.isEmpty && filteredBooks.isEmpty {
                        ContentUnavailableView.search(text: trimmedQuery)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(DS.Surface.grouped)
            }
            .navigationTitle("快速跳转")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { searchFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func shortcutHint(for space: WorkspaceNavigation.PadSpace) -> String? {
        switch space {
        case .chat: return "⌘1"
        case .bookshelf: return "⌘2"
        case .friends: return "⌘3"
        case .workshop: return "⌘4"
        case .settings: return "⌘,"
        case .usage: return nil
        }
    }

    private func commandRow(title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.readableText)
                    .frame(width: 24)
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DS.Surface.neutralChipFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(minHeight: DS.TouchTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
