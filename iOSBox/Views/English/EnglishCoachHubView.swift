import SwiftUI
import SwiftData

/// Main hub for Night-Run Autonomous Personal English Coach ("语习私教"):
/// Zero-textbook daily micro-lessons, word-level shadowing, scenario roleplay, study journal, and persistent learner memory.
struct EnglishCoachHubView: View {
    enum CoachTab: String, CaseIterable, Identifiable {
        case today
        case journal
        case memory

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return String(localized: "今日私教")
            case .journal: return String(localized: "学习日志")
            case .memory: return String(localized: "学情记忆")
            }
        }
    }

    var onClose: (() -> Void)? = nil
    var journalOnly = false

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var store = EnglishCoachStore.shared
    @State private var speechCoach = EnglishSpeechCoachService.shared
    @State private var preferences = AppPreferences.shared
    @State private var consent = AIConsentGate()

    @State private var selectedTab: CoachTab = .today
    @State private var onboardingDraft = EnglishLearnerProfile()
    @State private var showProfileEditor = false
    @State private var showQuickKeySetup = false
    @State private var showRoleplaySheet = false
    @State private var showCustomTopicAlert = false
    @State private var customTopicDraft = ""
    @State private var showTutorNotesEditor = false
    @State private var tutorNotesDraft = ""
    @State private var showAddWeakWordAlert = false
    @State private var newWeakWordDraft = ""

    @State private var isGeneratingLesson = false
    @State private var coachingDrillID: UUID?
    @State private var isArchivingLesson = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var resolvedModelTuple: (target: ResolvedModelTarget, provider: ProviderConfig, spec: ModelSpec)? {
        EnglishTutorLLMService.resolveTutorTarget(
            preferredID: store.profile.preferredTargetID,
            providers: providers
        )
    }

    private var allReadyTargets: [ResolvedModelTarget] {
        ProviderConfig.readyTargets(in: providers)
    }

    var body: some View {
        if journalOnly {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    ForEach(store.journalEntries) { journalEntryCard($0) }
                }.padding(DS.Spacing.lg)
            }
            .background(DS.Surface.grouped)
            .navigationTitle("学习日志")
            .onDisappear { speechCoach.stopSpeaking() }
        } else {
            coach
        }
    }

    private var coach: some View {
        NavigationStack {
            Group {
                if !store.hasCompletedOnboarding {
                    onboardingScrollContent
                } else {
                    VStack(spacing: 0) {
                        Picker("语习栏目", selection: $selectedTab) {
                            ForEach(CoachTab.allCases) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(DS.Surface.drawer)

                        Divider().overlay(DS.Surface.hairline)

                        ScrollView {
                            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                                switch selectedTab {
                                case .today:
                                    todayLessonSection
                                case .journal:
                                    journalSection
                                case .memory:
                                    memorySection
                                }
                            }
                            .padding(DS.Spacing.lg)
                        }
                    }
                }
            }
            .background(DS.Surface.grouped.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") {
                            speechCoach.stopSpeaking()
                            speechCoach.stopRecording()
                            onClose()
                        }
                        .tint(.primary)
                    }
                }

                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        FugueSealMark(character: "語", size: 22, theme: theme)
                        Text("语习私教")
                            .font(.system(.headline, design: .serif).weight(.bold))
                    }
                }

                if store.hasCompletedOnboarding {
                    ToolbarItem(placement: .topBarTrailing) {
                        toolbarModelMenu
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.solidForeground)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(theme.solidFill, in: Capsule())
                        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .aiConsentSheet(consent)
            .sheet(isPresented: $showQuickKeySetup) {
                QuickKeySetupSheet()
            }
            .sheet(isPresented: $showRoleplaySheet) {
                EnglishRoleplaySheetView(providers: providers) {
                    withAnimation(.snappy) {
                        selectedTab = .journal
                    }
                    showToast(String(localized: "今日训练已归档至学习日志"))
                }
            }
            .sheet(isPresented: $showProfileEditor) {
                learnerProfileEditorSheet
            }
            .sheet(isPresented: $showTutorNotesEditor) {
                tutorNotesEditorSheet
            }
            .alert("指定今日想练的场景", isPresented: $showCustomTopicAlert) {
                TextField("例如：向外国同事解释线上 Bug 原因、机场改签航班…", text: $customTopicDraft)
                Button("取消", role: .cancel) { customTopicDraft = "" }
                Button("立即备课") {
                    let directive = customTopicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    customTopicDraft = ""
                    generateTodayLesson(customDirective: directive.isEmpty ? nil : directive)
                }
            } message: {
                Text("AI 外教会结合你的学情记忆，围绕该主题定制表达与跟读句。")
            }
            .alert("手动添加跟读练习词", isPresented: $showAddWeakWordAlert) {
                TextField("输入英文单词，如 schedule / rural", text: $newWeakWordDraft)
                    .textInputAutocapitalization(.never)
                Button("取消", role: .cancel) { newWeakWordDraft = "" }
                Button("添加") {
                    let word = newWeakWordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    newWeakWordDraft = ""
                    if !word.isEmpty {
                        store.recordWeakWord(word)
                        store.save()
                    }
                }
            }
            .alert(
                "私教提示",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                if resolvedModelTuple == nil {
                    Button("秒配模型 Key") {
                        errorMessage = nil
                        showQuickKeySetup = true
                    }
                }
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                onboardingDraft = store.profile
            }
            .onDisappear {
                speechCoach.stopSpeaking()
                speechCoach.stopRecording()
            }
        }
    }

    // MARK: - Toolbar Model & Settings Menu

    @ViewBuilder
    private var toolbarModelMenu: some View {
        Menu {
            if allReadyTargets.isEmpty {
                Button {
                    showQuickKeySetup = true
                } label: {
                    Label("剪贴板秒配模型 Key", systemImage: "bolt.fill")
                }
            } else {
                Section("私教驱动模型") {
                    Button {
                        store.profile.preferredTargetID = nil
                    } label: {
                        HStack {
                            Text("跟随全局默认模型")
                            if store.profile.preferredTargetID == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    ForEach(allReadyTargets, id: \.id) { target in
                        Button {
                            store.profile.preferredTargetID = target.id
                        } label: {
                            HStack {
                                Text("\(target.modelDisplayName) · \(target.providerName)")
                                if store.profile.preferredTargetID == target.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                onboardingDraft = store.profile
                showProfileEditor = true
            } label: {
                Label("调整水平、口音与目标", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: resolvedModelTuple == nil ? "bolt.trianglebadge.exclamationmark" : "cpu")
                    .font(.caption.weight(.semibold))
                Text(resolvedModelTuple?.target.modelDisplayName ?? String(localized: "配模型"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(resolvedModelTuple == nil ? theme.readableText : .primary)
            .padding(.horizontal, 10)
            .frame(minHeight: DS.TouchTarget.minimum)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("选择外教模型与偏好")
    }

    // MARK: - First-Launch 20-Second Onboarding

    private var onboardingScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack(spacing: 10) {
                        FugueSealMark(character: "初", size: 30, theme: theme)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("定制你的无课本 AI 英语私教")
                                .font(.system(.title3, design: .serif).weight(.bold))
                                .foregroundStyle(.primary)
                            Text("每天自动排课 · 逐词跟读对照 · 情景陪练 · 持续学情记忆")
                                .font(.caption)
                                .foregroundStyle(DS.Surface.inkSecondary)
                        }
                    }

                    Text("告别死背固定教材。你的模型外教会根据你的水平、职业兴趣与每次开口暴露的薄弱点，动态生成专属每日微课与学习日志。")
                        .font(DS.Typography.prose(size: 14.5, serif: preferences.literarySerifBody))
                        .foregroundStyle(DS.Surface.inkSecondary)
                        .lineSpacing(4)
                }
                .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)

                profileFormFields(draft: $onboardingDraft)

                VStack(spacing: DS.Spacing.sm) {
                    Button {
                        preferences.triggerSelectionHaptic()
                        store.completeOnboarding(with: onboardingDraft)
                        if resolvedModelTuple != nil {
                            generateTodayLesson()
                        } else {
                            store.loadSampleStarterLesson()
                            showToast(String(localized: "已为你加载首节互动体验微课"))
                        }
                    } label: {
                        Label(
                            resolvedModelTuple != nil
                                ? String(localized: "开启私教 · 生成今日第 1 课")
                                : String(localized: "保存偏好并开启首节体验课"),
                            systemImage: "sparkles"
                        )
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(theme.solidForeground)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(theme.solidFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if resolvedModelTuple != nil {
                        Button {
                            preferences.triggerSelectionHaptic()
                            store.completeOnboarding(with: onboardingDraft)
                            store.loadSampleStarterLesson()
                        } label: {
                            Text("先免消耗 Token 体验内置互动样课")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DS.Surface.inkSecondary)
                                .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
    }

    @ViewBuilder
    private func profileFormFields(draft: Binding<EnglishLearnerProfile>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("1. 当前英语开口阶段")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)

            ForEach(EnglishProficiencyLevel.allCases) { level in
                let selected = draft.wrappedValue.level == level
                Button {
                    preferences.triggerSelectionHaptic()
                    draft.wrappedValue.level = level
                } label: {
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? theme.readableText : DS.Surface.inkSecondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(level.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(level.subtitle)
                                .font(.caption)
                                .foregroundStyle(DS.Surface.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(DS.Spacing.md)
                    .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                    .background(
                        selected ? theme.softFill : DS.Surface.card,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .strokeBorder(selected ? theme.tintColor.opacity(0.35) : DS.Surface.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("2. 核心学习场景")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)

            ForEach(EnglishLearningGoal.allCases) { goal in
                let selected = draft.wrappedValue.goal == goal
                Button {
                    preferences.triggerSelectionHaptic()
                    draft.wrappedValue.goal = goal
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: goal.icon)
                            .font(.subheadline)
                            .foregroundStyle(selected ? theme.readableText : DS.Surface.inkSecondary)
                            .frame(width: 24)
                        Text(goal.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(theme.readableText)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                    .background(
                        selected ? theme.softFill : DS.Surface.card,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .strokeBorder(selected ? theme.tintColor.opacity(0.35) : DS.Surface.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("3. 标准口音与每日预算")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)

            HStack(spacing: DS.Spacing.xs) {
                ForEach(EnglishAccentPreference.allCases) { accent in
                    let selected = draft.wrappedValue.accent == accent
                    Button {
                        preferences.triggerSelectionHaptic()
                        draft.wrappedValue.accent = accent
                    } label: {
                        Text(accent.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? theme.solidForeground : .primary)
                            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                            .background(
                                selected ? theme.solidFill : DS.Surface.card,
                                in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                    .strokeBorder(selected ? Color.clear : DS.Surface.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: DS.Spacing.xs) {
                ForEach([10, 15, 25], id: \.self) { mins in
                    let selected = draft.wrappedValue.dailyMinutes == mins
                    Button {
                        preferences.triggerSelectionHaptic()
                        draft.wrappedValue.dailyMinutes = mins
                    } label: {
                        Text("\(mins) 分钟 / 天")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(selected ? theme.readableText : .primary)
                            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                            .background(
                                selected ? theme.softFill : DS.Surface.card,
                                in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                    .strokeBorder(selected ? theme.tintColor.opacity(0.35) : DS.Surface.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("4. 个人职业或兴趣标签（选填，让话题更贴身）")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)

            TextField(
                "例如：iOS 独立开发、远程团队协作、科幻电影、精品咖啡…",
                text: draft.customInterest,
                axis: .vertical
            )
            .lineLimit(2...4)
            .padding(DS.Spacing.md)
            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(DS.Surface.hairline, lineWidth: 1)
            )
        }
    }

    // MARK: - Tab 1: Today's Autonomous Lesson

    @ViewBuilder
    private var todayLessonSection: some View {
        todayStatusHeader

        if isGeneratingLesson {
            VStack(spacing: DS.Spacing.md) {
                ProgressView()
                Text("AI 外教正在翻阅你的学情记忆与薄弱词，定制今日专属微课…")
                    .font(.subheadline)
                    .foregroundStyle(DS.Surface.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.xl)
        } else if let lesson = store.activeLesson {
            scenarioHeroCard(lesson)
            chunksSection(lesson)
            EnglishShadowingSectionView(
                drills: lesson.drills,
                accent: store.profile.accent,
                coachingDrillID: coachingDrillID,
                onEvaluateDrill: { drillID, summary in
                    store.recordShadowingEvaluation(drillID: drillID, evaluation: summary)
                },
                onRequestAICoach: { drill in
                    requestShadowingCoach(for: drill)
                }
            )
            roleplayAndArchiveCard(lesson)
        } else {
            emptyLessonStartCard
        }
    }

    private var todayStatusHeader: some View {
        HStack(spacing: DS.Spacing.xs) {
            DSBadge(
                text: store.currentStreakDays > 0
                    ? String(localized: "连续 \(store.currentStreakDays) 天")
                    : String(localized: "第 \(store.nextDayNumber) 课"),
                icon: store.currentStreakDays > 0 ? "flame.fill" : "calendar",
                style: .accent(theme)
            )

            DSBadge(
                text: store.profile.level.title,
                style: .neutral
            )

            DSBadge(
                text: store.profile.accent == .us ? "US" : "UK",
                icon: "speaker.wave.2",
                style: .neutral
            )

            Spacer()

            Menu {
                Button {
                    generateTodayLesson()
                } label: {
                    Label("AI 重新排一节新微课", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    showCustomTopicAlert = true
                } label: {
                    Label("指定今日想练的场景…", systemImage: "text.bubble")
                }

                Divider()

                Button {
                    store.profile.difficultyAdjustment = max(-2, store.profile.difficultyAdjustment - 1)
                    generateTodayLesson(customDirective: "Please make sentences shorter, clearer, and slightly easier.")
                } label: {
                    Label("觉得偏难 · 调低难度重排", systemImage: "arrow.down.right.circle")
                }

                Button {
                    store.profile.difficultyAdjustment = min(2, store.profile.difficultyAdjustment + 1)
                    generateTodayLesson(customDirective: "Please elevate idiomatic richness and natural speed.")
                } label: {
                    Label("觉得轻松 · 提高难度重排", systemImage: "arrow.up.right.circle")
                }

                Divider()

                Button {
                    store.loadSampleStarterLesson()
                } label: {
                    Label("加载内置互动示例微课", systemImage: "doc.richtext")
                }
            } label: {
                Label("排课微调", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: DS.TouchTarget.minimum)
                    .background(DS.Surface.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Surface.hairline, lineWidth: 1))
            }
        }
    }

    private var emptyLessonStartCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: 10) {
                FugueSealMark(character: "課", size: 28, theme: theme)
                VStack(alignment: .leading, spacing: 2) {
                    Text("准备好开始今天的英语开口了吗？")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("包含 3 个高频地道短语、阶梯逐词跟读对照与沉浸情景对话。")
                        .font(.caption)
                        .foregroundStyle(DS.Surface.inkSecondary)
                }
            }

            if !store.memory.weakWords.isEmpty || !store.memory.grammarBlindspots.isEmpty {
                Text("将自动融合复习你近期记录的 \(store.memory.weakWords.count) 个跟读练习词与 \(store.memory.grammarBlindspots.count) 处表达盲区。")
                    .font(.caption)
                    .foregroundStyle(theme.readableText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }

            Button {
                generateTodayLesson()
            } label: {
                Label("AI 动态生成今日微课", systemImage: "sparkles")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(theme.solidForeground)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(theme.solidFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: DS.Spacing.sm) {
                Button {
                    store.loadSampleStarterLesson()
                } label: {
                    Label("体验示例微课", systemImage: "play.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                        .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)

                if resolvedModelTuple == nil {
                    Button {
                        showQuickKeySetup = true
                    } label: {
                        Label("连接模型", systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.readableText)
                            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                            .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
    }

    private func scenarioHeroCard(_ lesson: EnglishDailyLesson) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("DAY \(lesson.dayNumber) · \(lesson.dateKey)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(theme.readableText)
                Spacer()
                if lesson.isCompleted {
                    DSBadge(text: "已记入日志", icon: "checkmark.seal.fill", style: .accent(.teal))
                }
            }

            Text(lesson.title)
                .font(.system(size: 21, weight: .bold, design: .serif))
                .foregroundStyle(.primary)

            if !lesson.scenarioBrief.isEmpty {
                Text(lesson.scenarioBrief)
                    .font(DS.Typography.prose(size: 14.5, serif: preferences.literarySerifBody))
                    .foregroundStyle(DS.Surface.inkSecondary)
                    .lineSpacing(4)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "target")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.readableText)
                    .padding(.top, 2)
                Text("实战目标：\(lesson.roleplayMission)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
    }

    @ViewBuilder
    private func chunksSection(_ lesson: EnglishDailyLesson) -> some View {
        if !lesson.chunks.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack {
                    Label("今日地道语块 (\(lesson.chunks.count))", systemImage: "quote.opening")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                }

                ForEach(lesson.chunks) { chunk in
                    chunkCard(chunk)
                }
            }
        }
    }

    private func chunkCard(_ chunk: EnglishLessonChunk) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chunk.phrase)
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                    if !chunk.phonetic.isEmpty {
                        Text(chunk.phonetic)
                            .font(.caption.monospaced())
                            .foregroundStyle(DS.Surface.inkSecondary)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        preferences.triggerSelectionHaptic()
                        speechCoach.speakEnglish(chunk.phrase, accent: store.profile.accent, slow: false)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.readableText)
                            .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                            .background(theme.softFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("朗读短语 \(chunk.phrase)")

                    Button {
                        preferences.triggerSelectionHaptic()
                        speechCoach.speakEnglish(chunk.phrase, accent: store.profile.accent, slow: true)
                    } label: {
                        Image(systemName: "tortoise.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                            .background(DS.Surface.subtle, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("慢速朗读短语 \(chunk.phrase)")
                }
            }

            Text(chunk.meaningZh)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if !chunk.usageTip.isEmpty {
                Text(chunk.usageTip)
                    .font(.caption)
                    .foregroundStyle(DS.Surface.inkSecondary)
            }

            if !chunk.chinglishTrap.isEmpty {
                Label("避坑：\(chunk.chinglishTrap)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(DS.AccentTheme.amber.readableText)
            }

            if !chunk.nativeExample.isEmpty {
                Button {
                    preferences.triggerSelectionHaptic()
                    speechCoach.speakEnglish(chunk.nativeExample, accent: store.profile.accent, slow: false)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(theme.readableText)
                            Text(chunk.nativeExample)
                                .font(.system(size: 14.5, weight: .medium, design: .serif))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        if !chunk.exampleZh.isEmpty {
                            Text(chunk.exampleZh)
                                .font(.caption)
                                .foregroundStyle(DS.Surface.inkSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                    .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.md)
    }

    private func roleplayAndArchiveCard(_ lesson: EnglishDailyLesson) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("情景开口实战与日志归档")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("跟读已练 \(lesson.completedDrillCount)/\(lesson.drills.count) 句 · 实战对话 \(lesson.learnerTurnCount) 轮 · 激活表达 \(lesson.activatedPhrases.count) 个")
                        .font(.caption)
                        .foregroundStyle(DS.Surface.inkSecondary)
                }
                Spacer()
            }

            Button {
                preferences.triggerSelectionHaptic()
                showRoleplaySheet = true
            } label: {
                Label("进入情景语音实战陪练", systemImage: "waveform.and.mic")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(theme.solidForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(theme.solidFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                archiveCurrentLessonDirectly(lesson)
            } label: {
                HStack(spacing: 6) {
                    if isArchivingLesson {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "book.closed.fill")
                    }
                    Text(lesson.isCompleted ? String(localized: "更新今日学习日志摘要") : String(localized: "完成今日训练并记入学习日志"))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isArchivingLesson)
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
    }

    // MARK: - Tab 2: Study Journal Timeline

    @ViewBuilder
    private var journalSection: some View {
        HStack(spacing: DS.Spacing.sm) {
            DSMetricTile(
                title: String(localized: "连续打卡"),
                value: String(localized: "\(store.currentStreakDays) 天"),
                valueTint: theme.readableText
            )
            DSMetricTile(
                title: String(localized: "累计微课"),
                value: "\(store.journalEntries.count)"
            )
            DSMetricTile(
                title: String(localized: "习得表达"),
                value: "\(store.memory.masteredChunks.count)",
                valueTint: DS.StatusText.success
            )
        }

        if store.journalEntries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Label("尚无学习日志记录", systemImage: "book.pages")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("每完成一节今日微课或情景语音陪练，系统都会自动在此沉淀你的跟读文本匹配度、地道表达对照以及 AI 外教的成长点评。")
                    .font(.subheadline)
                    .foregroundStyle(DS.Surface.inkSecondary)
                    .lineSpacing(3)
                Button {
                    selectedTab = .today
                } label: {
                    Text("前往今日私教开始练习")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.readableText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .background(theme.softFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
        } else {
            ForEach(store.journalEntries) { entry in
                journalEntryCard(entry)
            }
        }
    }

    private func journalEntryCard(_ entry: EnglishStudyLogEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Text(entry.dateKey)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(theme.readableText)

                if let avg = entry.averagePronunciationScore {
                    DSBadge(
                        text: String(localized: "平均文本匹配度 \(avg)%"),
                        icon: "waveform",
                        style: .accent(.teal)
                    )
                }

                if entry.spokenTurnCount > 0 {
                    DSBadge(
                        text: String(localized: "开口 \(entry.spokenTurnCount) 轮"),
                        icon: "bubble.left.and.bubble.right.fill",
                        style: .neutral
                    )
                }
                Spacer()
            }

            Text(entry.lessonTitle)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(.primary)

            HStack(alignment: .top, spacing: 8) {
                FugueSealMark(character: "評", size: 18, theme: theme)
                    .padding(.top, 2)
                Text(entry.tutorSummary)
                    .font(DS.Typography.prose(size: 14, serif: preferences.literarySerifBody))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))

            if !entry.newChunks.isEmpty {
                WrappingWordFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(entry.newChunks, id: \.self) { phrase in
                        Button {
                            speechCoach.speakEnglish(phrase, accent: store.profile.accent, slow: false)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2")
                                    .font(.caption2)
                                Text(phrase)
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(DS.Surface.subtle, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !entry.recastPairs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("表达升格对照")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DS.Surface.inkSecondary)

                    ForEach(entry.recastPairs) { pair in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原句：\(pair.learnerSaid)")
                                .font(.caption)
                                .foregroundStyle(DS.Surface.inkSecondary)
                            HStack {
                                Text("地道：\(pair.nativeVersion)")
                                    .font(.system(size: 14, weight: .semibold, design: .serif))
                                    .foregroundStyle(DS.AccentTheme.teal.readableText)
                                Spacer()
                                Button {
                                    speechCoach.speakEnglish(pair.nativeVersion, accent: store.profile.accent, slow: false)
                                } label: {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption)
                                        .foregroundStyle(DS.AccentTheme.teal.readableText)
                                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("朗读地道表达")
                            }
                        }
                        .padding(8)
                        .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    }
                }
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
    }

    // MARK: - Tab 3: Persistent Learner Memory

    @ViewBuilder
    private var memorySection: some View {
        // 1. Profile overview card
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Label("个人学习档案", systemImage: "person.text.rectangle")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button {
                    onboardingDraft = store.profile
                    showProfileEditor = true
                } label: {
                    Text("编辑偏好")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.readableText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .background(theme.softFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Text("\(store.profile.level.title) · \(store.profile.goal.title) · \(store.profile.accent.title) · 每日 \(store.profile.dailyMinutes) 分钟")
                .font(.caption)
                .foregroundStyle(DS.Surface.inkSecondary)

            if !store.profile.customInterest.isEmpty {
                Text("关注话题：\(store.profile.customInterest)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.md)

        // 2. Long-term AI Tutor Notes
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Label("外教学情长期画像", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button {
                    tutorNotesDraft = store.memory.tutorNotes
                    showTutorNotesEditor = true
                } label: {
                    Text("编辑备注")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .background(DS.Surface.subtle, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(
                store.memory.tutorNotes.isEmpty
                    ? String(localized: "完成微课结课后，AI 外教会在此自动归纳你的语感优势与待强化细节；你也可以手动补充希望外教重点关注的方向。")
                    : store.memory.tutorNotes
            )
            .font(DS.Typography.prose(size: 14, serif: preferences.literarySerifBody))
            .foregroundStyle(store.memory.tutorNotes.isEmpty ? DS.Surface.inkSecondary : .primary)
            .lineSpacing(4)
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.md)

        // 3. Pronunciation Weak Words
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Label("跟读练习词本 (\(store.memory.weakWords.count))", systemImage: "ear.badge.waveform")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button {
                    showAddWeakWordAlert = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.readableText)
                        .padding(.horizontal, 10)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .background(theme.softFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if store.memory.weakWords.isEmpty {
                Text("跟读时未匹配到的单词会自动收录于此，并在后续每日微课中自然复现。")
                    .font(.caption)
                    .foregroundStyle(DS.Surface.inkSecondary)
            } else {
                ForEach(store.memory.weakWords) { item in
                    HStack(spacing: DS.Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.word)
                                    .font(.system(size: 16, weight: .bold, design: .serif))
                                    .foregroundStyle(.primary)
                                DSBadge(text: String(localized: "偏差 \(item.missCount) 次"), style: .accent(.vermilion))
                            }
                            if !item.heardAs.isEmpty {
                                Text("曾被识别为：\(item.heardAs.joined(separator: " / "))")
                                    .font(.caption2)
                                    .foregroundStyle(DS.Surface.inkSecondary)
                            }
                        }
                        Spacer()
                        Button {
                            speechCoach.speakEnglish(item.word, accent: store.profile.accent, slow: true)
                        } label: {
                            Image(systemName: "tortoise.fill")
                                .font(.caption)
                                .foregroundStyle(theme.readableText)
                                .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                                .background(theme.softFill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("慢速示范 \(item.word)")

                        Button {
                            store.removeWeakWord(id: item.id)
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.subheadline)
                                .foregroundStyle(DS.Surface.inkSecondary)
                                .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("标记已掌握并移除 \(item.word)")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.md)

        // 4. Grammar & Chinglish Blindspots
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label("语法与中式表达盲区 (\(store.memory.grammarBlindspots.count))", systemImage: "pencil.and.outline")
                .font(.subheadline.weight(.bold))

            if store.memory.grammarBlindspots.isEmpty {
                Text("情景对话中被外教纠偏的语法习惯与中式直译会自动归类到这里。")
                    .font(.caption)
                    .foregroundStyle(DS.Surface.inkSecondary)
            } else {
                ForEach(store.memory.grammarBlindspots) { spot in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            DSBadge(text: spot.pattern, style: .accent(.amber))
                            if spot.occurrences > 1 {
                                Text("出现 \(spot.occurrences) 次")
                                    .font(.caption2)
                                    .foregroundStyle(DS.Surface.inkSecondary)
                            }
                            Spacer()
                            Button {
                                store.removeGrammarBlindspot(id: spot.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(DS.Surface.inkSecondary)
                                    .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除盲区 \(spot.pattern)")
                        }
                        Text("原句：\(spot.userExample)")
                            .font(.caption)
                            .foregroundStyle(DS.Surface.inkSecondary)
                        Text("地道：\(spot.nativeFix)")
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                            .foregroundStyle(DS.AccentTheme.teal.readableText)
                    }
                    .padding(10)
                    .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.md)
    }

    // MARK: - Auxiliary Editor Sheets

    private var learnerProfileEditorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    profileFormFields(draft: $onboardingDraft)
                }
                .padding(DS.Spacing.lg)
            }
            .background(DS.Surface.grouped)
            .navigationTitle("学习目标与口音偏好")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showProfileEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.completeOnboarding(with: onboardingDraft)
                        showProfileEditor = false
                        showToast(String(localized: "学情偏好已更新"))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var tutorNotesEditorSheet: some View {
        NavigationStack {
            Form {
                Section("外教备课长期参考备注") {
                    TextField(
                        "例如：请多安排产品设计评审话题，重点纠正我的冠词 a/the 与过去完成时…",
                        text: $tutorNotesDraft,
                        axis: .vertical
                    )
                    .lineLimit(4...10)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Surface.grouped)
            .navigationTitle("编辑学情画像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showTutorNotesEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateTutorNotes(tutorNotesDraft)
                        showTutorNotesEditor = false
                        showToast(String(localized: "学情画像备注已保存"))
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func generateTodayLesson(customDirective: String? = nil) {
        guard let resolved = resolvedModelTuple else {
            errorMessage = EnglishTutorError.noReadyModel.localizedDescription
            return
        }
        let recipient = AppCompliance.recipient(
            provider: resolved.provider.name,
            model: resolved.target.modelDisplayName,
            baseURL: resolved.provider.baseURL
        )
        consent.perform(recipients: [recipient], search: false, tools: false) {
            isGeneratingLesson = true
            Task { @MainActor in
                defer { isGeneratingLesson = false }
                do {
                    let lesson = try await EnglishTutorLLMService.generateDailyLesson(
                        profile: store.profile,
                        memory: store.memory,
                        dayNumber: store.nextDayNumber,
                        recentTopics: store.recentTopicTitles,
                        customDirective: customDirective,
                        target: resolved.target,
                        provider: resolved.provider,
                        spec: resolved.spec,
                        context: modelContext
                    )
                    store.setActiveLesson(lesson)
                    preferences.triggerLightHaptic()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func requestShadowingCoach(for drill: EnglishShadowingDrill) {
        guard let resolved = resolvedModelTuple else {
            errorMessage = EnglishTutorError.noReadyModel.localizedDescription
            return
        }
        let recipient = AppCompliance.recipient(
            provider: resolved.provider.name,
            model: resolved.target.modelDisplayName,
            baseURL: resolved.provider.baseURL
        )
        let spoken = drill.lastSpokenTranscript ?? ""
        let missed = (drill.lastEvaluationTokens ?? []).filter { $0.state == .missed }.map(\.expectedWord)
        let fuzzy = (drill.lastEvaluationTokens ?? []).filter { $0.state == .fuzzy }.map(\.expectedWord)

        consent.perform(recipients: [recipient], search: false, tools: false) {
            coachingDrillID = drill.id
            Task { @MainActor in
                defer { coachingDrillID = nil }
                do {
                    let coaching = try await EnglishTutorLLMService.coachShadowingAttempt(
                        drill: drill,
                        spokenTranscript: spoken,
                        missedWords: missed,
                        fuzzyWords: fuzzy,
                        accent: store.profile.accent,
                        target: resolved.target,
                        provider: resolved.provider,
                        spec: resolved.spec,
                        context: modelContext
                    )
                    store.setShadowingCoachFeedback(drillID: drill.id, feedback: coaching)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func archiveCurrentLessonDirectly(_ lesson: EnglishDailyLesson) {
        guard let resolved = resolvedModelTuple, AppCompliance.hasAcceptedAIDisclosure() else {
            let fallback = String(
                localized: "已完成《\(lesson.title)》微课训练：跟读 \(lesson.completedDrillCount)/\(lesson.drills.count) 句，实战开口 \(lesson.learnerTurnCount) 轮。"
            )
            store.finalizeLessonToJournal(tutorSummary: fallback, updatedTutorNotes: nil)
            withAnimation(.snappy) { selectedTab = .journal }
            showToast(String(localized: "已归档至学习日志"))
            return
        }

        isArchivingLesson = true
        Task { @MainActor in
            defer { isArchivingLesson = false }
            let result = try? await EnglishTutorLLMService.summarizeLessonForJournal(
                lesson: lesson,
                profile: store.profile,
                memory: store.memory,
                target: resolved.target,
                provider: resolved.provider,
                spec: resolved.spec,
                context: modelContext
            )
            let summary = result?.tutorSummary ?? String(
                localized: "已完成《\(lesson.title)》微课训练：跟读 \(lesson.completedDrillCount)/\(lesson.drills.count) 句，实战开口 \(lesson.learnerTurnCount) 轮。"
            )
            store.finalizeLessonToJournal(tutorSummary: summary, updatedTutorNotes: result?.updatedTutorNotes)
            withAnimation(.snappy) { selectedTab = .journal }
            showToast(String(localized: "今日训练已归档至学习日志"))
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            toastMessage = text
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if toastMessage == text {
                withAnimation(.easeOut(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}
