import SwiftUI
import SwiftData

/// Unified Context Inspector replacing multi-level modal hops for session routing,
/// bound knowledge volumes, capability toggles, and branch/token telemetry.
struct ChatContextInspectorSheet: View {
    @Bindable var conversation: Conversation
    let providers: [ProviderConfig]
    @Binding var omitKnowledgeOnce: Bool
    let onOpenModelPicker: () -> Void
    let onOpenKnowledgePicker: () -> Void
    let onOpenFullSettings: () -> Void
    let onOpenCitation: (ReadingCitation) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @State private var preferences = AppPreferences.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var activeMessages: [ChatMessage] {
        ConversationTree.activeMessages(in: conversation)
    }

    private var boundBooks: [BookVolume] {
        let ids = Set(conversation.assistanceSettings.knowledgeVolumeIDs)
        return books.filter { ids.contains($0.id) }
    }

    private var latestSources: [ReadingCitation] {
        guard let last = activeMessages.last(where: { $0.role == .assistant && !$0.isStreaming }) else { return [] }
        return ReadingReferences(knowledge: last.assistanceMetadata.knowledgeEvidence,
                                 book: last.assistanceMetadata.bookReply,
                                 friend: conversation.activeBookFriend,
                                 limits: conversation.readingChapterLimits).sources
    }

    private var totalPromptTokens: Int {
        activeMessages.compactMap(\.promptTokens).reduce(0, +)
    }

    private var totalCompletionTokens: Int {
        activeMessages.compactMap(\.completionTokens).reduce(0, +)
    }

    private var totalCachedTokens: Int {
        activeMessages.compactMap(\.cachedTokens).reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("当前模型与路由") {
                    if conversation.isGroupMode {
                        LabeledContent("会话模式", value: String(localized: "圆桌群聊 (\(conversation.activeGroupMembers.count) 人)"))
                    } else if conversation.isArenaMode {
                        Button {
                            dismiss()
                            onOpenModelPicker()
                        } label: {
                            HStack {
                                Label("并发对比模型", systemImage: "square.split.2x1")
                                Spacer()
                                Text("\(conversation.arenaTargets.count) 个模型")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    } else {
                        Button {
                            dismiss()
                            onOpenModelPicker()
                        } label: {
                            HStack {
                                Label("主回答模型", systemImage: "cpu")
                                Spacer()
                                Text(conversation.primaryTarget?.modelDisplayName ?? String(localized: "未选择"))
                                    .foregroundStyle(theme.readableText)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Toggle("按内容自动能力路由", isOn: $conversation.assistanceSettings.automaticRouting)
                        Toggle("429 / 超时自动故障降级", isOn: $conversation.assistanceSettings.fallbackEnabled)
                    }
                }

                if conversation.activeBookFriend == nil {
                    Section("挂载参考知识库") {
                        if boundBooks.isEmpty {
                            Text("暂未绑定本地书架文档")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(boundBooks) { book in
                                Label(book.title, systemImage: "book.closed.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                            }
                            Toggle("下一条提问临时跳过知识库", isOn: $omitKnowledgeOnce)
                        }

                        Button {
                            dismiss()
                            onOpenKnowledgePicker()
                        } label: {
                            Label("管理绑定书目 (\(boundBooks.count))", systemImage: "books.vertical")
                                .fontWeight(.medium)
                        }
                    }
                }

                if !latestSources.isEmpty {
                    Section("最近回答实际使用的资料") {
                        ForEach(latestSources, id: \.number) { source in
                            ReadingCitationButton(citation: source) { citation in
                                dismiss()
                                onOpenCitation(citation)
                            }
                        }
                    }
                }

                if !conversation.isGroupMode {
                    Section("推演与辅助能力") {
                        Toggle("启用深度思考链", isOn: $conversation.enableThinking)
                        if !conversation.isArenaMode {
                            Toggle("启用智能工具", isOn: $conversation.assistanceSettings.enableAgentTools)
                        }
                        Toggle("服务商原生联网 Grounding", isOn: $conversation.assistanceSettings.enableNativeGrounding)
                        Toggle("携带个人长期记忆", isOn: $conversation.assistanceSettings.usePersonalMemory)
                    }
                }

                Section("本会话脉络与 Token 统计") {
                    LabeledContent("当前分支消息数", value: "\(activeMessages.count)")
                    if conversation.messages.count > activeMessages.count {
                        LabeledContent("全部分支总节点", value: "\(conversation.messages.count)")
                    }
                    LabeledContent("累计输入 Token", value: totalPromptTokens.formatted())
                    LabeledContent("累计输出 Token", value: totalCompletionTokens.formatted())
                    if totalCachedTokens > 0 {
                        LabeledContent("累计缓存命中", value: totalCachedTokens.formatted())
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onOpenFullSettings()
                    } label: {
                        Label("打开完整系统提示词与采样参数…", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Surface.grouped)
            .navigationTitle("会话检视器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.medium)
                }
            }
        }
    }
}
