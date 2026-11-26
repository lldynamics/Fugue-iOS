import SwiftData
import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var usesPhoneWorkspace = false
}

enum PhoneWorkspaceTab: String, CaseIterable {
    case conversation, library

    var title: LocalizedStringKey {
        switch self {
        case .conversation: "对话"
        case .library: "资料库"
        }
    }

    var symbol: String {
        switch self {
        case .conversation: "bubble.left"
        case .library: "book"
        }
    }
}

struct PhoneWorkspaceTabBar: View {
    let selection: PhoneWorkspaceTab
    let accent: DS.AccentTheme
    let onSelect: (PhoneWorkspaceTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PhoneWorkspaceTab.allCases, id: \.self) { tab in
                Button { onSelect(tab) } label: {
                    VStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: tab.symbol).font(.body.weight(.medium))
                        Text(tab.title).font(.caption.weight(.medium))
                    }
                    .foregroundStyle(selection == tab ? accent.readableText : .secondary)
                    .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.title))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("workspace.tab.\(tab.rawValue)")
            }
        }
        .padding(.vertical, DS.Spacing.xxs)
        .background(DS.Surface.canvas.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().accessibilityHidden(true) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.bottomDock")
    }
}

struct PhoneWorkspaceRow: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(verbatim: title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                if let subtitle {
                    Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(minHeight: DS.TouchTarget.minimum)
        .contentShape(Rectangle())
    }
}

struct PhoneLibraryView: View {
    let books: [BookVolume]
    let onOpenSection: (AssistantListView.WorkshopSection) -> Void
    let onResumeReading: (Conversation) -> Void
    let onOpenSettings: () -> Void
    let onOpenUsage: () -> Void

    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query private var readingStates: [ShelfReadingState]
    @State private var preferences = AppPreferences.shared

    private var readingSession: (book: BookVolume, chat: Conversation, chapter: String?)? {
        guard !books.isEmpty else { return nil }
        for chat in conversations {
            guard let id = chat.readingVolumeID,
                  let book = books.first(where: { $0.id == id }), chat.isCompanion(for: id) else { continue }
            let index = readingStates.first(where: { $0.bookID == id })?.chapter ?? 0
            let chapter = book.chapterTitles.indices.contains(index) ? book.chapterTitles[index] : nil
            return (book, chat, chapter)
        }
        return nil
    }

    var body: some View {
        List {
            if let session = readingSession {
                Section("继续阅读") {
                    Button { onResumeReading(session.chat) } label: {
                        PhoneWorkspaceRow(title: session.book.title, subtitle: session.chapter, symbol: "book")
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DS.Surface.card)
                    .accessibilityIdentifier("workspace.workshop.resumeReading")
                }
            }
            Section("资料") {
                shortcut(.books, title: "书架", subtitle: String(localized: "\(books.count) 本"), symbol: "books.vertical")
            }
            Section("助手与学习") {
                shortcut(.presets, title: "助手预设", symbol: "sparkles")
                if preferences.showsBookFriends {
                    shortcut(.friends, title: "好友", symbol: "person.2")
                }
                if preferences.showsGroupChat {
                    shortcut(.roundtables, title: "圆桌沙龙", symbol: "person.3")
                }
                if preferences.showsEnglishCoach {
                    shortcut(.study, title: "学习", symbol: "rectangle.on.rectangle")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.Surface.canvas)
        .navigationTitle("资料库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Label("设置", systemImage: "gearshape")
                }
                .accessibilityIdentifier("workspace.settings")
            }
            if preferences.showsUsageTab {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenUsage) { Label("用量", systemImage: "chart.bar.xaxis") }
                        .accessibilityIdentifier("workspace.usage")
                }
            }
        }
    }

    private func shortcut(
        _ section: AssistantListView.WorkshopSection,
        title: String.LocalizationValue,
        subtitle: String? = nil,
        symbol: String
    ) -> some View {
        Button { onOpenSection(section) } label: {
            PhoneWorkspaceRow(title: String(localized: title), subtitle: subtitle, symbol: symbol)
        }
        .buttonStyle(.plain)
        .listRowBackground(DS.Surface.card)
        .accessibilityIdentifier("workspace.workshop.\(section.id)")
    }
}
