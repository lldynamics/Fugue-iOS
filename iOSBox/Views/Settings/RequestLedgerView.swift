import SwiftUI
import SwiftData
import Charts

struct RequestLedgerView: View {
    @Query(sort: \RequestRecord.startedAt, order: .reverse) private var records: [RequestRecord]
    @Query(filter: #Predicate<ChatMessage> { $0.comparisonGroupID != nil && $0.synthesisSourceDigest == nil })
    private var arenaMessages: [ChatMessage]
    @State private var period: LedgerPeriod = .month
    @State private var referenceDate = Date()
    @State private var providerID: UUID?
    @State private var modelID: String?
    @State private var visibleLimit = 50
    @State private var showsFilters = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var preferences = AppPreferences.shared
    @State private var showBudgetSheet = false
    @State private var budgetLimitInput = ""
    @State private var budgetCurrencyInput = "USD"
    @State private var budgetAlertRatioInput = 0.8

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private func overallMedianTPS(in records: [RequestRecord]) -> (tps: Double, count: Int)? {
        let samples = records.compactMap(\.tokensPerSecond).sorted()
        guard !samples.isEmpty else { return nil }
        let mid = samples.count / 2
        let median = samples.count.isMultiple(of: 2)
            ? (samples[mid - 1] + samples[mid]) / 2.0
            : samples[mid]
        return (median, samples.count)
    }

    private func compactTokenText(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private var providerOptions: [(UUID, String)] {
        var seen = Set<UUID>()
        return records.filter { seen.insert($0.providerID).inserted }.map { ($0.providerID, $0.providerName) }
    }

    private var modelOptions: [String] {
        Set(records.filter { providerID == nil || $0.providerID == providerID }.map(\.modelID)).sorted()
    }

    private var filtered: [RequestRecord] {
        records.filter {
            period.includes($0.startedAt, now: referenceDate) && (providerID == nil || $0.providerID == providerID)
                && (modelID == nil || $0.modelID == modelID)
        }
    }

    var body: some View {
        let rows = filtered
        let modelRows = rows.filter { $0.kind != .webSearch }
        let totalPrompt = rows.compactMap { LLMUsage.valid($0.promptTokens) }.reduce(0, LLMUsage.saturatedSum)
        let totalCompletion = rows.compactMap { LLMUsage.valid($0.completionTokens) }.reduce(0, LLMUsage.saturatedSum)
        let totalCached = rows.compactMap { LLMUsage.valid($0.cachedTokens) }.reduce(0, LLMUsage.saturatedSum)
        let succeededCount = rows.filter { $0.status == .succeeded }.count
        let totals = RequestLedger.costs(modelRows)
        let savings = RequestLedger.cacheSavings(modelRows)
        let unpricedCount = modelRows.filter { $0.status != .running && $0.status != .blocked && !$0.hasModelPricing }.count
        let monthSpentByCurrency = RequestLedger.costs(
            records.filter { $0.kind != .webSearch && LedgerPeriod.month.includes($0.startedAt) }
        )
        let budgetEval = MonthlyBudgetEvaluator.evaluate(
            spentByCurrency: monthSpentByCurrency,
            limit: preferences.monthlyBudgetLimit,
            currency: preferences.monthlyBudgetCurrency,
            alertRatio: preferences.monthlyBudgetAlertRatio
        )

        return NavigationStack {
            List {
                Section {
                    let speedSummary = overallMedianTPS(in: modelRows)
                    let speedText = speedSummary.map { "\($0.tps.formatted(.number.precision(.fractionLength(1)))) tok/s" } ?? "—"
                    let speedDetail = speedSummary.map { String(localized: "\($0.count) 样本") }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm),
                                             count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: DS.Spacing.sm) {
                        DSMetricTile(
                            title: String(localized: "预估费用"),
                            value: RequestLedger.costOverviewText(totals: totals, modelRecords: modelRows, requestCount: rows.count),
                            detail: additionalCostDetail(totals: totals, savings: savings, unpricedCount: unpricedCount)
                        )
                        DSMetricTile(
                            title: String(localized: "请求次数"), value: "\(rows.count)",
                            detail: String(localized: "完整 \(succeededCount)")
                        )
                        if !rows.isEmpty {
                            DSMetricTile(title: String(localized: "中位速率"), value: speedText,
                                         detail: speedDetail, valueTint: theme.readableText)
                            DSMetricTile(title: String(localized: "已知 Token"),
                                         value: compactTokenText(LLMUsage.saturatedSum(totalPrompt, totalCompletion)),
                                         detail: totalCached > 0 ? String(localized: "缓存命中 \(compactTokenText(totalCached))") : nil)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                    if rows.isEmpty {
                        Text(emptyMessage).foregroundStyle(.primary)
                            .accessibilityIdentifier("usage.empty")
                    }
                } header: {
                    Text(periodTitle).foregroundStyle(.primary).accessibilityIdentifier("usage.period")
                }

                if budgetEval.level == .warning || budgetEval.level == .exceeded {
                    Section {
                        Button(action: openBudgetEditor) {
                            Label(budgetStatusLine(for: budgetEval), systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.primary)
                        }
                        .accessibilityIdentifier("usage.budgetWarning")
                    }
                }

                filterSection
                if !rows.isEmpty {
                    Section("用量与预估费用") {
                        let buckets = RequestLedger.trendBuckets(rows, period: period)
                        if buckets.count >= 2 {
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                Text("Token 消耗趋势")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Chart(buckets) { item in
                                    BarMark(
                                        x: .value(String(localized: "时间"), item.date, unit: period == .today ? .hour : (period == .month ? .day : .month)),
                                        y: .value("Tokens", item.totalTokens)
                                    )
                                    .foregroundStyle(theme.tintColor.gradient)
                                    .cornerRadius(4)
                                }
                                .frame(height: 135)
                            }
                            .padding(.vertical, DS.Spacing.xxs)
                        }

                        LabeledContent("请求次数", value: String(rows.count))
                        LabeledContent("完整完成", value: String(succeededCount))
                        LabeledContent("已知输入 Token", value: Double(totalPrompt).formatted(.number.precision(.fractionLength(0))))
                        LabeledContent("已知输出 Token", value: Double(totalCompletion).formatted(.number.precision(.fractionLength(0))))
                        if totalCached > 0 {
                            LabeledContent("缓存命中 Token", value: Double(totalCached).formatted(.number.precision(.fractionLength(0))))
                        }
                        let searchCount = rows.count - modelRows.count
                        if searchCount > 0 { Text("含联网搜索 \(searchCount) 次；搜索费用另计。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(totals.keys.sorted(), id: \.self) { currency in
                            LabeledContent("预估费用", value: RequestLedger.costText(totals[currency] ?? 0, currency: currency))
                        }
                        ForEach(savings.keys.sorted(), id: \.self) { currency in
                            LabeledContent("缓存已节省", value: RequestLedger.costText(savings[currency] ?? 0, currency: currency))
                                .foregroundStyle(.primary)
                        }
                        if totals.isEmpty { Text("暂无可计价记录").foregroundStyle(.primary) }
                        let unpriced = modelRows.filter { $0.status != .running && $0.status != .blocked && $0.estimatedCost == nil }.count
                        Text("缺少用量或单价：\(unpriced) 次（不按零费用计算）")
                            .font(.footnote).foregroundStyle(Color(uiColor: .label))
                        Text("按请求开始时间归入本地日期。费用采用请求当时的单价，不合并不同币种；可在服务商的模型列表设置单价。")
                            .font(.footnote).foregroundStyle(Color(uiColor: .label))
                    }
                }

                let groups = RequestLedger.groups(modelRows)
                let rankedSpeedGroups = Array(groups.filter { $0.medianTPS != nil }.prefix(6))

                if !groups.isEmpty {
                    Section {
                        if rankedSpeedGroups.count >= 2 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("输出吞吐速率对比 (tok/s)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Chart(rankedSpeedGroups) { item in
                                    BarMark(
                                        x: .value("tok/s", item.medianTPS ?? 0),
                                        y: .value(String(localized: "模型"), "\(item.modelName) (\(item.providerName))")
                                    )
                                    .foregroundStyle(theme.tintColor.gradient)
                                    .cornerRadius(4)
                                    .annotation(position: .trailing) {
                                        if let tps = item.medianTPS {
                                            Text("\(tps.formatted(.number.precision(.fractionLength(1))))")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(height: CGFloat(max(90, rankedSpeedGroups.count * 34)))
                            }
                            .padding(.vertical, DS.Spacing.xxs)
                        }

                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(group.modelName).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    if let tps = group.medianTPS {
                                        Text("≈ \(tps.formatted(.number.precision(.fractionLength(1)))) tok/s")
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(theme.readableText)
                                    }
                                }
                                Text("\(group.providerName) · \(group.kind.title)").font(.caption).foregroundStyle(.secondary)
                                Text("已完成 \(group.completed.count)/\(group.records.count) · 速度样本 \(group.speedSampleCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: DS.Spacing.md) {
                                    if let first = group.medianFirstOutputMs {
                                        Text("首段 \(RequestLedger.seconds(Int(first)))")
                                    }
                                    if let content = group.medianFirstContentMs {
                                        Text("正文 \(RequestLedger.seconds(Int(content)))")
                                    }
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                ForEach(group.costs.keys.sorted(), id: \.self) { currency in
                                    Text(RequestLedger.costText(group.costs[currency] ?? 0, currency: currency)).font(.caption)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        Text("测速榜（中位数）").foregroundStyle(.primary)
                    } footer: {
                        Text("按服务商、模型和请求类型分组。首段包含思考；正文为首个正文片段。速度仅统计完整流式回复，用 API 返回的输出 Token 除以首末输出间隔，可能包含思考 Token。不同提示词和输入长度会影响结果。")
                    }
                }

                let blindLeaderboard = ArenaBallot.standings(from: arenaMessages)
                if !blindLeaderboard.isEmpty || arenaMessages.contains(where: {
                    $0.assistanceMetadataData != nil && $0.assistanceMetadata.blindArenaRevealed
                }) {
                    Section {
                        if blindLeaderboard.isEmpty { Text("尚无独立选票").foregroundStyle(.secondary) }
                        ForEach(blindLeaderboard) { stat in
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(stat.modelName)
                                            .font(.subheadline.weight(.semibold))
                                        Text(stat.providerName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(stat.winRate, format: .percent.precision(.fractionLength(0)))
                                            .font(.subheadline.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(theme.readableText)
                                        Text("胜 \(stat.wins)/\(stat.rounds)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                ProgressView(value: min(max(stat.winRate, 0), 1))
                                    .tint(theme.tintColor)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("双盲评测胜率榜")
                    } footer: {
                        Text("胜率按投票时已完成的回答统计。旧版已揭晓的轮次没有独立选票，不计入胜率。")
                    }
                }

                if !rows.isEmpty {
                    Section("请求明细") {
                        ForEach(Array(rows.prefix(visibleLimit))) { record in
                            NavigationLink {
                                RequestRecordDetailView(record: record)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(record.modelDisplayName).lineLimit(1)
                                        Spacer()
                                        if let cost = record.estimatedCost, let currency = record.currency {
                                            Text(RequestLedger.costText(cost, currency: currency))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        } else if record.kind != .webSearch, record.status != .running, record.status != .blocked, !record.hasModelPricing {
                                            Text("未定价").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(record.status.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("\(record.providerName) · \(record.kind.title) · #\(record.attempt)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(record.startedAt, format: .dateTime.month().day().hour().minute().second())
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if rows.count > visibleLimit {
                            Button("显示更多") { visibleLimit += 50 }
                        }
                    }
                }
            }
            .navigationTitle("用量与测速")
            .toolbar {
                Button(action: openBudgetEditor) { Label("月度预算", systemImage: "gauge.with.dots.needle.50percent") }
                    .accessibilityIdentifier("usage.budget")
            }
            .onChange(of: referenceDate) { _, _ in visibleLimit = 50 }
            .onChange(of: providerID) { _, _ in modelID = nil; visibleLimit = 50 }
            .onChange(of: period) { _, _ in visibleLimit = 50 }
            .onChange(of: modelID) { _, _ in visibleLimit = 50 }
            .sheet(isPresented: $showBudgetSheet) {
                NavigationStack {
                    Form {
                        if budgetEval.level != .unconfigured {
                            Section("月度预算监控") {
                                LabeledContent("预估费用", value: RequestLedger.costText(budgetEval.spent, currency: budgetEval.currency))
                                Text(budgetStatusLine(for: budgetEval))
                            }
                        }
                        Section {
                            TextField("每月预算金额（填 0 停用）", text: $budgetLimitInput)
                                .keyboardType(.decimalPad)
                            Picker("预算币种", selection: $budgetCurrencyInput) {
                                ForEach(RequestRecord.currencies, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("预警阈值", selection: $budgetAlertRatioInput) {
                                Text("70%").tag(0.7)
                                Text("80%").tag(0.8)
                                Text("90%").tag(0.9)
                            }
                        } footer: {
                            Text("预算监控统计当前自然月内所选币种的预估费用，达到阈值或超支时将在账本顶部提示。")
                        }
                    }
                    .navigationTitle("设置月度预算")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showBudgetSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                let normalized = budgetLimitInput
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .replacingOccurrences(of: ",", with: ".")
                                let parsed = Double(normalized) ?? 0
                                preferences.monthlyBudgetLimit = (parsed.isFinite && parsed > 0) ? parsed : 0
                                preferences.monthlyBudgetCurrency = budgetCurrencyInput
                                preferences.monthlyBudgetAlertRatio = budgetAlertRatioInput
                                showBudgetSheet = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var periodTitle: String {
        switch period {
        case .month: referenceDate.formatted(.dateTime.year().month(.wide))
        case .today: referenceDate.formatted(date: .long, time: .omitted)
        case .all: String(localized: "全部时间")
        }
    }

    private var emptyMessage: String {
        if providerID != nil || modelID != nil { return String(localized: "当前筛选下没有请求") }
        switch period {
        case .month:
            return LedgerPeriod.month.includes(referenceDate) ? String(localized: "本月还没有请求") : String(localized: "该月没有请求")
        case .today:
            return Calendar.current.isDateInToday(referenceDate) ? String(localized: "今天还没有请求") : String(localized: "当天没有请求")
        case .all: return String(localized: "暂无请求记录")
        }
    }

    private var filterSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsFilters) {
                Picker("统计周期", selection: $period) {
                    ForEach(LedgerPeriod.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if period == .today {
                    DatePicker("统计日期", selection: $referenceDate, displayedComponents: [.date])
                } else if period == .month {
                    HStack {
                        monthButton(offset: -1, title: "上个月", icon: "chevron.backward")
                        Spacer()
                        Text(periodTitle)
                        Spacer()
                        monthButton(offset: 1, title: "下个月", icon: "chevron.forward")
                    }
                }
                Picker("服务商", selection: $providerID) {
                    Text("全部").tag(UUID?.none)
                    ForEach(providerOptions, id: \.0) { id, name in Text(name).tag(Optional(id)) }
                }
                Picker("模型", selection: $modelID) {
                    Text("全部").tag(String?.none)
                    ForEach(modelOptions, id: \.self) { Text($0).tag(Optional($0)) }
                }
            } label: {
                HStack {
                    Label("筛选", systemImage: "line.3.horizontal.decrease")
                    Spacer()
                    Text(verbatim: [providerOptions.first { $0.0 == providerID }?.1, modelID]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("usage.filters")
        }
    }

    private func monthButton(offset: Int, title: LocalizedStringKey, icon: String) -> some View {
        Button {
            if let month = Calendar.current.date(byAdding: .month, value: offset, to: referenceDate) {
                referenceDate = month
            }
        } label: {
            Image(systemName: icon).frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(title))
    }

    private func additionalCostDetail(totals: [String: Double], savings: [String: Double], unpricedCount: Int) -> String? {
        let currencies = totals.keys.sorted()
        guard let first = currencies.first else { return nil }
        var details = currencies.dropFirst().map { RequestLedger.costText(totals[$0] ?? 0, currency: $0) }
        if unpricedCount > 0 {
            details.insert(String(localized: "另有 \(unpricedCount) 次未定价"), at: 0)
        } else if currencies.count == 1, let saved = savings[first], saved > 0 {
            details.append(String(localized: "缓存省 \(RequestLedger.costText(saved, currency: first))"))
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func openBudgetEditor() {
        budgetLimitInput = preferences.monthlyBudgetLimit > 0
            ? preferences.monthlyBudgetLimit.formatted(.number.precision(.fractionLength(0...4)))
            : ""
        budgetCurrencyInput = preferences.monthlyBudgetCurrency
        let currentRatio = preferences.monthlyBudgetAlertRatio
        if abs(currentRatio - 0.7) < 0.05 {
            budgetAlertRatioInput = 0.7
        } else if abs(currentRatio - 0.9) < 0.05 {
            budgetAlertRatioInput = 0.9
        } else {
            budgetAlertRatioInput = 0.8
        }
        showBudgetSheet = true
    }

    private func budgetStatusLine(for evaluation: MonthlyBudgetEvaluation) -> String {
        switch evaluation.level {
        case .unconfigured:
            return ""
        case .exceeded:
            return String(localized: "已超支或达本月预算上限，建议切换轻量模型或本地模型")
        case .warning:
            return String(localized: "已接近本月预算上限，剩余 \(RequestLedger.costText(evaluation.remaining, currency: evaluation.currency))")
        case .normal:
            return String(localized: "本月预算充足，剩余 \(RequestLedger.costText(evaluation.remaining, currency: evaluation.currency))")
        }
    }
}

struct RequestRecordDetailView: View {
    let record: RequestRecord

    var body: some View {
        Form {
            Section("请求") {
                LabeledContent("服务商", value: record.providerName)
                LabeledContent("模型", value: record.modelID)
                LabeledContent("类型", value: record.kind.title)
                LabeledContent("状态", value: record.status.title)
                LabeledContent("尝试次数", value: String(record.attempt))
                if let status = record.httpStatus { LabeledContent("HTTP", value: String(status)) }
                Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
            }
            if record.kind == .webSearch {
                Section("搜索调用") {
                    metric("总耗时", value: record.durationMs)
                    Text("搜索不使用模型 Token 计价，费用请以 Tavily 账单为准。成功结果的来源与返回额度保存在对应回答中。")
                }
            } else {
                Section("耗时与用量") {
                    metric("首段输出", value: record.firstOutputMs)
                    metric("首段思考", value: record.firstReasoningMs)
                    metric("首段正文", value: record.firstContentMs)
                    metric("总耗时", value: record.durationMs)
                    LabeledContent("输入 Token", value: record.promptTokens.map(String.init) ?? String(localized: "未返回"))
                    LabeledContent("输出 Token", value: record.completionTokens.map(String.init) ?? String(localized: "未返回"))
                    if let cached = record.cachedTokens, cached > 0 {
                        LabeledContent("缓存命中 Token", value: String(cached))
                    }
                    if let cacheWrite = record.cacheWriteTokens, cacheWrite > 0 {
                        LabeledContent("缓存写入 Token", value: String(cacheWrite))
                    }
                    if let tps = record.tokensPerSecond {
                        LabeledContent("输出速率（估算）", value: String(format: "%.1f tok/s", tps))
                    }
                    if !record.isStreamed { Text("服务商返回了非流式结果，不计算输出速率。").font(.caption) }
                }
                Section("请求时的计价") {
                    if let currency = record.currency { LabeledContent("币种", value: currency) }
                    LabeledContent("每百万输入 Token 单价", value: record.inputPricePerMillion.map { $0.formatted() } ?? String(localized: "未设置"))
                    LabeledContent("每百万输出 Token 单价", value: record.outputPricePerMillion.map { $0.formatted() } ?? String(localized: "未设置"))
                    if let cacheReadPrice = record.cacheReadPricePerMillion {
                        LabeledContent("每百万缓存命中单价", value: cacheReadPrice.formatted())
                    }
                    if let cacheWritePrice = record.cacheWritePricePerMillion {
                        LabeledContent("每百万缓存写入单价", value: cacheWritePrice.formatted())
                    }
                    if let cost = record.estimatedCost, let currency = record.currency {
                        LabeledContent("预估费用", value: RequestLedger.costText(cost, currency: currency))
                        if let saved = record.estimatedCacheSavings {
                            LabeledContent("缓存已节省", value: RequestLedger.costText(saved, currency: currency))
                                .foregroundStyle(.green)
                        }
                    } else { Text("用量或单价不完整，费用未知。") }
                    Text("按服务商返回用量与已设单价（含缓存单价快照）估算，不含阶梯价格和额外收费。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("请求详情").navigationBarTitleDisplayMode(.inline)
    }

    private func metric(_ title: LocalizedStringKey, value: Int?) -> some View {
        LabeledContent(title, value: value.map(RequestLedger.seconds) ?? "—")
    }
}
