import AppIntents
import SwiftUI
import WidgetKit

enum QuickEntryActionChoice: String, AppEnum {
    case newChat = "new-chat"
    case voiceNote = "voice-note"
    case scanDocument = "scan-document"
    case bookmarks = "bookmarks"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "快捷动作"
    static var caseDisplayRepresentations: [QuickEntryActionChoice: DisplayRepresentation] = [
        .newChat: DisplayRepresentation(title: "新建对话", image: .init(systemName: "square.and.pencil")),
        .voiceNote: DisplayRepresentation(title: "录音纪要", image: .init(systemName: "waveform.and.mic")),
        .scanDocument: DisplayRepresentation(title: "扫描文档", image: .init(systemName: "doc.viewfinder")),
        .bookmarks: DisplayRepresentation(title: "收藏知识库", image: .init(systemName: "bookmark.fill"))
    ]

    var action: QuickEntryAction {
        switch self {
        case .newChat: return .newChat
        case .voiceNote: return .voiceNote
        case .scanDocument: return .scanDocument
        case .bookmarks: return .bookmarks
        }
    }
}

struct QuickActionWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择快捷入口"
    static var description = IntentDescription("配置小组件点击后直达的常用功能。")

    @Parameter(title: "快捷动作", default: .newChat)
    var action: QuickEntryActionChoice

    init() {}

    init(action: QuickEntryActionChoice) {
        self.action = action
    }
}

struct QuickLaunchTimelineEntry: TimelineEntry {
    let date: Date
    let action: QuickEntryAction
    let snapshot: WidgetSnapshot
}

struct QuickLaunchTimelineProvider: AppIntentTimelineProvider {
    func recommendations() -> [AppIntentRecommendation<QuickActionWidgetIntent>] {
        [
            AppIntentRecommendation(intent: QuickActionWidgetIntent(action: .newChat), description: String(localized: "新建对话")),
            AppIntentRecommendation(intent: QuickActionWidgetIntent(action: .voiceNote), description: String(localized: "录音纪要")),
            AppIntentRecommendation(intent: QuickActionWidgetIntent(action: .scanDocument), description: String(localized: "扫描文档")),
            AppIntentRecommendation(intent: QuickActionWidgetIntent(action: .bookmarks), description: String(localized: "收藏知识库"))
        ]
    }

    func placeholder(in context: Context) -> QuickLaunchTimelineEntry {
        QuickLaunchTimelineEntry(date: .now, action: .newChat, snapshot: .empty)
    }

    func snapshot(for configuration: QuickActionWidgetIntent, in context: Context) async -> QuickLaunchTimelineEntry {
        QuickLaunchTimelineEntry(
            date: .now,
            action: configuration.action.action,
            snapshot: WidgetSnapshotStore().load()
        )
    }

    func timeline(for configuration: QuickActionWidgetIntent, in context: Context) async -> Timeline<QuickLaunchTimelineEntry> {
        let entry = QuickLaunchTimelineEntry(
            date: .now,
            action: configuration.action.action,
            snapshot: WidgetSnapshotStore().load()
        )
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}

struct IOSBoxQuickLaunchWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: QuickEntryWidgetKind.quickLaunch,
            intent: QuickActionWidgetIntent.self,
            provider: QuickLaunchTimelineProvider()
        ) { entry in
            QuickLaunchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("夜奔快捷入口")
        .description("从桌面或锁屏一键启动新对话、录音纪要、文档扫描 OCR 或收藏知识库。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

private struct QuickLaunchWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickLaunchTimelineEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallHomeView
                .containerBackground(for: .widget) { homeWidgetBackground }
                .widgetURL(entry.action.deepLinkURL)

        case .systemMedium:
            mediumHomeView
                .containerBackground(for: .widget) { homeWidgetBackground }
                .widgetURL(QuickEntryAction.newChat.deepLinkURL)

        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.action.systemImage)
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(entry.action.deepLinkURL)

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: entry.action.systemImage)
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 2) {
                    Text("夜奔")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.action.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.action.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(entry.action.deepLinkURL)

        case .accessoryInline:
            Label("夜奔 · \(entry.action.shortTitle)", systemImage: entry.action.systemImage)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.action.deepLinkURL)

        default:
            smallHomeView
                .containerBackground(for: .widget) { homeWidgetBackground }
                .widgetURL(entry.action.deepLinkURL)
        }
    }

    private var homeWidgetBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.11, blue: 0.19),
                Color(red: 0.12, green: 0.16, blue: 0.28)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var smallHomeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
                Text("夜奔")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            Image(systemName: entry.action.systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.action.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            if entry.snapshot.bookmarkedCount > 0 {
                Text("收藏 \(entry.snapshot.bookmarkedCount) 条")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.cyan.opacity(0.9))
            } else {
                Text("轻点直达")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumHomeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                Text("夜奔快捷入口")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                statusBadge
            }

            if entry.snapshot.showRecentTitles && !entry.snapshot.recentConversations.isEmpty {
                HStack(spacing: 8) {
                    ForEach(QuickEntryAction.allCases) { item in
                        Link(destination: item.deepLinkURL) {
                            VStack(spacing: 4) {
                                Image(systemName: item.systemImage)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.cyan)
                                Text(item.shortTitle)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.snapshot.recentConversations.prefix(2))) { item in
                        if let url = URL(string: "iosbox://conversation/\(item.id.uuidString)") {
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: item.isPinned ? "pin.fill" : "bubble.left")
                                        .font(.caption2)
                                        .foregroundStyle(.cyan.opacity(0.85))
                                    Text(item.title)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(1)
                                        .privacySensitive()
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            } else {
                let topRow = [QuickEntryAction.newChat, QuickEntryAction.voiceNote]
                let bottomRow = [QuickEntryAction.scanDocument, QuickEntryAction.bookmarks]
                VStack(spacing: 8) {
                    actionGridRow(topRow)
                    actionGridRow(bottomRow)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if entry.snapshot.bookmarkedCount > 0 {
            Text("已就绪 \(entry.snapshot.readyModelCount) 模型 · 收藏 \(entry.snapshot.bookmarkedCount)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.12), in: Capsule())
        } else if entry.snapshot.readyModelCount > 0 {
            Text("已就绪 \(entry.snapshot.readyModelCount) 模型")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.12), in: Capsule())
        }
    }

    private func actionGridRow(_ actions: [QuickEntryAction]) -> some View {
        HStack(spacing: 8) {
            ForEach(actions) { item in
                Link(destination: item.deepLinkURL) {
                    HStack(spacing: 8) {
                        Image(systemName: item.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}
