import SwiftUI
import SwiftData
import Charts

struct RequestLedgerView: View {
    @Query(sort: \RequestRecord.startedAt, order: .reverse) private var records: [RequestRecord]
    @Query(filter: #Predicate<ChatMessage> { $0.comparisonGroupID != nil && !$0.isSynthesis })
    private var arenaMessages: [ChatMessage]
    @State private var period: LedgerPeriod = .month
    @State private var referenceDate = Date()
    @State private var providerID: UUID?
    @State private var modelID: String?
    @State private var visibleLimit = 50

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
        return NavigationStack {
            List {
                Section {
                    Picker("统计周期", selection: $period) {
                        ForEach(LedgerPeriod.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if period != .all {
                        DatePicker("统计日期", selection: $referenceDate, displayedComponents: [.date])
                    }
                    Picker("服务商", selection: $providerID) {
                        Text("全部").tag(UUID?.none)
                        ForEach(providerOptions, id: \.0) { id, name in Text(name).tag(Optional(id)) }
                    }
                    Picker("模型", selection: $modelID) {
                        Text("全部").tag(String?.none)
                        ForEach(modelOptions, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }

                Section("用量与预估费用") {
                    let buckets = RequestLedger.trendBuckets(rows, period: period)
                    if buckets.count >= 2 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Token 消耗趋势")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Chart(buckets) { item in
                                BarMark(
                                    x: .value(String(localized: "时间"), item.date, unit: period == .today ? .hour : (period == .month ? .day : .month)),
                                    y: .value("Tokens", item.totalTokens)
                                )
                                .foregroundStyle(Color.accentColor.gradient)
                                .cornerRadius(4)
                            }
                            .frame(height: 135)
                        }
                        .padding(.vertical, 4)
                    }

                    LabeledContent("请求次数", value: String(rows.count))
                    LabeledContent("完整完成", value: String(rows.filter { $0.status == .succeeded }.count))
                    LabeledContent("已知输入 Token", value: rows.compactMap(\.promptTokens).reduce(0.0) { $0 + Double($1) }.formatted(.number.precision(.fractionLength(0))))
                    LabeledContent("已知输出 Token", value: rows.compactMap(\.completionTokens).reduce(0.0) { $0 + Double($1) }.formatted(.number.precision(.fractionLength(0))))
                    let totalCached = rows.compactMap(\.cachedTokens).reduce(0, +)
                    if totalCached > 0 {
                        LabeledContent("缓存命中 Token", value: Double(totalCached).formatted(.number.precision(.fractionLength(0))))
                    }
                    let searchCount = rows.count - modelRows.count
                    if searchCount > 0 { Text("含联网搜索 \(searchCount) 次；搜索费用另计。").font(.caption).foregroundStyle(.secondary) }
                    let totals = RequestLedger.costs(modelRows)
                    ForEach(totals.keys.sorted(), id: \.self) { currency in
                        LabeledContent("预估费用", value: RequestLedger.costText(totals[currency] ?? 0, currency: currency))
                    }
                    let savings = RequestLedger.cacheSavings(modelRows)
                    ForEach(savings.keys.sorted(), id: \.self) { currency in
                        LabeledContent("缓存已节省", value: RequestLedger.costText(savings[currency] ?? 0, currency: currency))
                            .foregroundStyle(.green)
                    }
                    if totals.isEmpty { Text("暂无可计价记录").foregroundStyle(.secondary) }
                    let unpriced = modelRows.filter { $0.status != .running && $0.status != .blocked && $0.estimatedCost == nil }.count
                    Text("缺少用量或单价：\(unpriced) 次（不按零费用计算）")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("按请求开始时间归入本地日期。费用采用请求当时的单价，不合并不同币种；可在服务商的模型列表设置单价。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                let groups = RequestLedger.groups(modelRows)
                let rankedSpeedGroups = Array(groups.filter { $0.medianTPS != nil }.prefix(6))

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
                                .foregroundStyle(Color.accentColor.gradient)
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
                        .padding(.vertical, 4)
                    }

                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.modelName).font(.subheadline.weight(.semibold))
                            Text("\(group.providerName) · \(group.kind.title)").font(.caption).foregroundStyle(.secondary)
                            Text("已完成 \(group.completed.count)/\(group.records.count) · 速度样本 \(group.speedSampleCount)")
                                .font(.caption)
                            HStack {
                                if let first = group.medianFirstOutputMs {
                                    Text("首段 \(RequestLedger.seconds(Int(first)))")
                                }
                                if let content = group.medianFirstContentMs {
                                    Text("正文 \(RequestLedger.seconds(Int(content)))")
                                }
                            }.font(.caption.monospacedDigit())
                            if let tps = group.medianTPS {
                                Text("≈ \(tps.formatted(.number.precision(.fractionLength(1)))) tok/s")
                                    .font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
                            }
                            ForEach(group.costs.keys.sorted(), id: \.self) { currency in
                                Text(RequestLedger.costText(group.costs[currency] ?? 0, currency: currency)).font(.caption)
                            }
                        }.padding(.vertical, 3)
                    }
                } header: {
                    Text("测速榜（中位数）")
                } footer: {
                    Text("按服务商、模型和请求类型分组。首段包含思考；正文为首个正文片段。速度仅统计完整流式回复，用 API 返回的输出 Token 除以首末输出间隔，可能包含思考 Token。不同提示词和输入长度会影响结果。")
                }

                let blindLeaderboard = ArenaBallot.standings(from: arenaMessages)
                if !blindLeaderboard.isEmpty || arenaMessages.contains(where: {
                    $0.assistanceMetadataData != nil && $0.assistanceMetadata.blindArenaRevealed
                }) {
                    Section {
                        if blindLeaderboard.isEmpty { Text("尚无独立选票").foregroundStyle(.secondary) }
                        ForEach(blindLeaderboard) { stat in
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
                                        .foregroundStyle(Color.accentColor)
                                    Text("胜 \(stat.wins)/\(stat.rounds)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("双盲评测胜率榜")
                    } footer: {
                        Text("胜率按投票时已完成的回答统计。旧版已揭晓的轮次没有独立选票，不计入胜率。")
                    }
                }

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
                    if rows.isEmpty { Text("暂无请求记录").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("用量与测速")
            .onChange(of: providerID) { _, _ in modelID = nil; visibleLimit = 50 }
            .onChange(of: period) { _, _ in visibleLimit = 50 }
            .onChange(of: modelID) { _, _ in visibleLimit = 50 }
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
