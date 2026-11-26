import SwiftUI

enum PhoneComposeEntry {
    case writing, attachments
}

struct PhoneInboxView<Preview: View>: View {
    let conversations: [Conversation]
    let theme: DS.AccentTheme
    let preview: (Conversation) -> Preview
    let openConversation: (Conversation) -> Void
    let resumeDraft: (Conversation) -> Void
    let compose: (PhoneComposeEntry) -> Void
    let openArchive: () -> Void
    let search: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.calendar) private var calendar
    private let drafts = ChatDraftStore.shared

    private var latestDraft: Conversation? {
        let dates = drafts.draftDates
        guard !dates.isEmpty else { return nil }
        return conversations.lazy.filter { dates[$0.id] != nil }
            .max { dates[$0.id, default: .distantPast] < dates[$1.id, default: .distantPast] }
    }

    var body: some View {
        let draft = latestDraft
        let recent = conversations.lazy.filter { $0.id != draft?.id && !$0.messages.isEmpty }.prefix(3)
        VStack(spacing: 0) {
            if conversations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxl) {
                        searchButton
                        if let draft, let summary = drafts.previews[draft.id]?.summary {
                            draftButton(summary: summary) { resumeDraft(draft) }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                if !recent.isEmpty {
                                    Text("最近对话").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                                }
                                Spacer()
                                Button(action: openArchive) {
                                    HStack(spacing: DS.Spacing.xxs) {
                                        Text("全部对话")
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                                    }
                                    .font(.subheadline).foregroundStyle(DS.Surface.inkSecondary)
                                    .frame(minHeight: DS.TouchTarget.minimum)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("inbox.archive")
                            }
                            ForEach(Array(recent)) { chat in
                                recentRow(chat)
                                Divider().accessibilityHidden(true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.xl)
                    .padding(.top, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.xl)
                }
                .overlay(alignment: .bottom) {
                    // Soft edge so rows fade out above the compose bar instead of being cut.
                    LinearGradient(colors: [DS.Surface.canvas.opacity(0), DS.Surface.canvas],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: DS.Spacing.xl)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            composeBar
        }
        .buttonStyle(.plain)
        .background(DS.Surface.canvas)
        .navigationTitle("对话")
        .navigationBarTitleDisplayMode(.large)
        .task(id: scenePhase) {
            if scenePhase == .active { await drafts.loadInboxPreviews() }
        }
    }

    /// Looks like the system search bar under a large title; opens the full history search.
    private var searchButton: some View {
        Button(action: search) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                Text("搜索对话与书架").lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.body)
            .foregroundStyle(DS.Surface.inkSecondary)
            .padding(.horizontal, DS.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
            .background(DS.Surface.neutralChipFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("搜索对话与书架")
        .accessibilityIdentifier("inbox.search")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有对话", systemImage: "text.bubble")
        } description: {
            Text("在下方写个新问题开始，也可以点 ＋ 附上照片、文件或扫描文档。")
        }
        .foregroundStyle(DS.Surface.inkSecondary)
        .frame(maxHeight: .infinity)
    }

    private func draftButton(summary: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("待续草稿").font(.subheadline.weight(.medium)).foregroundStyle(DS.Surface.inkSecondary)
                Text(verbatim: summary).font(.custom("STSongti-SC-Regular", size: 22, relativeTo: .title3))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                HStack(spacing: DS.Spacing.sm) {
                    Text("接着写")
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
                .font(.headline).foregroundStyle(theme.readableText)
            }
            .padding(.leading, DS.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(theme.tintColor).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("inbox.resume")
    }

    private func recentRow(_ chat: Conversation) -> some View {
        Button { openConversation(chat) } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Spacing.xxs))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DS.Spacing.sm))
                layout {
                    Text(verbatim: chat.title).font(.title3.weight(.semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    dateLabel(chat.updatedAt).font(.subheadline).foregroundStyle(DS.Surface.inkSecondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                preview(chat)
            }
            .padding(.vertical, DS.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("inbox.recent.\(chat.id.uuidString)")
    }

    private func dateLabel(_ date: Date) -> Text {
        if calendar.isDateInToday(date) { return Text("今天") }
        if calendar.isDateInYesterday(date) { return Text("昨天") }
        if let lastWeek = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)),
           date > lastWeek, date < .now {
            return Text(date, format: .dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) { return Text(date, format: .dateTime.month().day()) }
        return Text(date, style: .date)
    }

    private var composeBar: some View {
        HStack(spacing: 0) {
            Button { compose(.attachments) } label: {
                Image(systemName: "plus").font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("添加附件并新建对话")
            .accessibilityIdentifier("inbox.attach")
            Rectangle().fill(DS.Surface.strongBorder).frame(width: 1, height: 20).accessibilityHidden(true)
            Button { compose(.writing) } label: {
                Text("写个新问题…").foregroundStyle(DS.Surface.inkSecondary)
                    .padding(.horizontal, DS.Spacing.md)
                    .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("inbox.newQuestion")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, DS.Spacing.xs)
        .background(DS.Surface.card, in: Capsule())
        .overlay { Capsule().strokeBorder(DS.Surface.strongBorder).allowsHitTesting(false) }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }
}
