import CryptoKit
import Foundation
import Observation

struct ProviderBalanceSnapshot: Equatable, Sendable {
    enum SourceKind: String, Equatable, Sendable {
        case openRouter
        case deepSeek
        case siliconFlow
        case moonshot
        case openAIBillingCompatible

        var label: String {
            switch self {
            case .openRouter: return "OpenRouter"
            case .deepSeek: return "DeepSeek"
            case .siliconFlow: return "SiliconFlow"
            case .moonshot: return "Moonshot"
            case .openAIBillingCompatible: return "Billing API"
            }
        }
    }

    let currency: String
    let available: Double?
    let used: Double?
    let total: Double?
    let isUnlimited: Bool
    let detailNote: String?
    let source: SourceKind
    let fetchedAt: Date

    var formattedAvailable: String {
        if isUnlimited {
            return String(localized: "无限额度")
        }
        guard let available else {
            if let used {
                return String(localized: "已用 \(Self.formatAmount(used, currency: currency))")
            }
            return "—"
        }
        return Self.formatAmount(available, currency: currency)
    }

    var formattedSecondaryDetail: String? {
        var parts: [String] = []
        if let used {
            parts.append(String(localized: "已用 \(Self.formatAmount(used, currency: currency))"))
        }
        if let total, !isUnlimited {
            parts.append(String(localized: "总额 \(Self.formatAmount(total, currency: currency))"))
        }
        if let detailNote, !detailNote.isEmpty {
            parts.append(detailNote)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func formatAmount(_ amount: Double, currency: String) -> String {
        let sign = amount < 0 ? "-" : ""
        let absVal = abs(amount)
        let formatted = absVal.formatted(.number.precision(.fractionLength(2...4)))
        return "\(currency) \(sign)\(formatted)"
    }
}

enum ProviderBalanceError: LocalizedError {
    case unsupportedEndpoint
    case missingAPIKey
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedEndpoint:
            return String(localized: "当前服务商接口暂未提供标准余额查询端点。")
        case .missingAPIKey:
            return String(localized: "请先配置有效的 API Key 后再查询余额。")
        case .invalidResponse:
            return String(localized: "服务商未返回可解析的额度信息。")
        case .httpStatus(let code, let detail):
            if code == 401 || code == 403 {
                return String(localized: "HTTP \(code) · 当前令牌无余额查询权限或密钥无效。")
            }
            if code == 404 {
                return String(localized: "该服务商或中转站未开放余额查询接口（HTTP 404）。")
            }
            return detail.isEmpty ? "HTTP \(code)" : "HTTP \(code)：\(detail)"
        }
    }
}

enum ProviderBalanceService {
    /// Returns true if the provider's protocol & URL can potentially answer a balance query
    /// (native official balance endpoints or OpenAI-compatible OneAPI/NewAPI billing endpoints).
    static func supportsBalanceQuery(protocolType: APIProtocolType, baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.localizedCaseInsensitiveContains("api.example.com"),
              !NetworkLocation.isLocalOrPrivate(baseURL: trimmed),
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: trimmed) else {
            return false
        }
        let clean = trimmed.hasSuffix("#") ? String(trimmed.dropLast()) : trimmed
        guard let host = URLComponents(string: clean)?.host?.lowercased() else { return false }
        if ["api.anthropic.com", "generativelanguage.googleapis.com", "api.openai.com",
            "api.groq.com", "api.x.ai", "dashscope.aliyuncs.com", "open.bigmodel.cn"].contains(host) {
            // Official OpenAI/Anthropic/Gemini/Groq/xAI/DashScope/Zhipu block API-key billing queries (require browser session keys).
            return false
        }
        if ["openrouter.ai", "api.deepseek.com", "api.siliconflow.cn", "api.siliconflow.com",
            "api.moonshot.cn", "api.moonshot.ai"].contains(host) || OpenAICompatibleAdapter.isOpenRouter(clean) {
            return true
        }
        // Custom OpenAI-compatible gateways (NewAPI / OneAPI / VoAPI) commonly expose /v1/dashboard/billing/*
        return protocolType == .openAICompatible
    }

    private static let ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    static func fetchBalance(
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        customHeaders: [CustomHeader] = [],
        session: URLSession = ephemeralSession,
        now: Date = Date()
    ) async throws -> ProviderBalanceSnapshot {
        let cleanKey = LLMClient.sanitizedAPIKey(apiKey)
        guard !cleanKey.isEmpty else { throw ProviderBalanceError.missingAPIKey }
        guard supportsBalanceQuery(protocolType: protocolType, baseURL: baseURL) else {
            throw ProviderBalanceError.unsupportedEndpoint
        }

        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutHash = trimmedURL.hasSuffix("#") ? String(trimmedURL.dropLast()) : trimmedURL
        guard let components = URLComponents(string: withoutHash),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            throw ProviderBalanceError.unsupportedEndpoint
        }

        if OpenAICompatibleAdapter.isOpenRouter(withoutHash) || host == "openrouter.ai" {
            return try await fetchOpenRouterBalance(apiKey: cleanKey, headers: customHeaders, session: session, now: now)
        }
        if host == "api.deepseek.com" {
            let data = try await getJSONData(
                url: URL(string: "https://api.deepseek.com/user/balance")!,
                apiKey: cleanKey,
                headers: customHeaders,
                session: session
            )
            return try parseDeepSeekBalance(data, now: now)
        }
        if host == "api.siliconflow.cn" || host == "api.siliconflow.com" {
            let endpoint = URL(string: "\(scheme)://\(host)/v1/user/info")!
            let data = try await getJSONData(url: endpoint, apiKey: cleanKey, headers: customHeaders, session: session)
            return try parseSiliconFlowBalance(data, now: now)
        }
        if host == "api.moonshot.cn" || host == "api.moonshot.ai" {
            let endpoint = URL(string: "\(scheme)://\(host)/v1/users/me/balance")!
            let data = try await getJSONData(url: endpoint, apiKey: cleanKey, headers: customHeaders, session: session)
            return try parseMoonshotBalance(data, now: now)
        }

        return try await fetchOpenAICompatibleBilling(
            baseComponents: components,
            apiKey: cleanKey,
            headers: customHeaders,
            session: session,
            now: now
        )
    }

    // MARK: - Platform Fetchers & Parsers

    private static func fetchOpenRouterBalance(
        apiKey: String,
        headers: [CustomHeader],
        session: URLSession,
        now: Date
    ) async throws -> ProviderBalanceSnapshot {
        do {
            let creditsData = try await getJSONData(
                url: URL(string: "https://openrouter.ai/api/v1/credits")!,
                apiKey: apiKey,
                headers: headers,
                session: session
            )
            return try parseOpenRouterCredits(creditsData, now: now)
        } catch {
            // Provisioned / scoped keys may forbid /credits but allow /api/v1/key
            let keyData = try await getJSONData(
                url: URL(string: "https://openrouter.ai/api/v1/key")!,
                apiKey: apiKey,
                headers: headers,
                session: session
            )
            return try parseOpenRouterKeyInfo(keyData, now: now)
        }
    }

    static func parseOpenRouterCredits(_ data: Data, now: Date = Date()) throws -> ProviderBalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = (root["data"] as? [String: Any]) ?? root as [String: Any]?,
              let totalCredits = doubleValue(payload["total_credits"]) else {
            throw ProviderBalanceError.invalidResponse
        }
        let totalUsage = doubleValue(payload["total_usage"]) ?? 0
        return ProviderBalanceSnapshot(
            currency: "USD",
            available: totalCredits - totalUsage,
            used: totalUsage,
            total: totalCredits,
            isUnlimited: false,
            detailNote: nil,
            source: .openRouter,
            fetchedAt: now
        )
    }

    static func parseOpenRouterKeyInfo(_ data: Data, now: Date = Date()) throws -> ProviderBalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            throw ProviderBalanceError.invalidResponse
        }
        let usage = doubleValue(payload["usage"])
        let limit = doubleValue(payload["limit"])
        let remaining = doubleValue(payload["limit_remaining"]) ?? limit.flatMap { lim in usage.map { lim - $0 } }
        let isFree = (payload["is_free_tier"] as? Bool) == true
        guard usage != nil || remaining != nil || limit != nil else {
            throw ProviderBalanceError.invalidResponse
        }
        return ProviderBalanceSnapshot(
            currency: "USD",
            available: remaining,
            used: usage,
            total: limit,
            isUnlimited: limit == nil && remaining == nil && !isFree,
            detailNote: isFree ? String(localized: "免费档令牌") : nil,
            source: .openRouter,
            fetchedAt: now
        )
    }

    static func parseDeepSeekBalance(_ data: Data, now: Date = Date()) throws -> ProviderBalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]],
              !infos.isEmpty else {
            throw ProviderBalanceError.invalidResponse
        }
        let preferred = infos.first { ($0["currency"] as? String)?.uppercased() == "CNY" } ?? infos[0]
        let currency = ((preferred["currency"] as? String) ?? "CNY").uppercased()
        guard let totalBalance = doubleValue(preferred["total_balance"]) else {
            throw ProviderBalanceError.invalidResponse
        }
        let granted = doubleValue(preferred["granted_balance"])
        var note: String? = nil
        if let granted, granted > 0 {
            note = String(localized: "含赠金 \(ProviderBalanceSnapshot.formatAmount(granted, currency: currency))")
        } else if (root["is_available"] as? Bool) == false {
            note = String(localized: "余额不足")
        }
        return ProviderBalanceSnapshot(
            currency: currency,
            available: totalBalance,
            used: nil,
            total: nil,
            isUnlimited: false,
            detailNote: note,
            source: .deepSeek,
            fetchedAt: now
        )
    }

    static func parseSiliconFlowBalance(_ data: Data, now: Date = Date()) throws -> ProviderBalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            throw ProviderBalanceError.invalidResponse
        }
        let totalBalance = doubleValue(payload["totalBalance"])
        let giftBalance = doubleValue(payload["balance"])
        let chargeBalance = doubleValue(payload["chargeBalance"])
        let resolvedAvailable = totalBalance ?? [giftBalance, chargeBalance].compactMap { $0 }.reduce(0, +)
        guard totalBalance != nil || giftBalance != nil || chargeBalance != nil else {
            throw ProviderBalanceError.invalidResponse
        }
        var note: String? = nil
        if let giftBalance, giftBalance > 0, chargeBalance != nil {
            note = String(localized: "含赠金 CNY \(giftBalance.formatted(.number.precision(.fractionLength(2))))")
        }
        return ProviderBalanceSnapshot(
            currency: "CNY",
            available: resolvedAvailable,
            used: nil,
            total: nil,
            isUnlimited: false,
            detailNote: note,
            source: .siliconFlow,
            fetchedAt: now
        )
    }

    static func parseMoonshotBalance(_ data: Data, now: Date = Date()) throws -> ProviderBalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let available = doubleValue(payload["available_balance"]) else {
            throw ProviderBalanceError.invalidResponse
        }
        let voucher = doubleValue(payload["voucher_balance"])
        let note = (voucher ?? 0) > 0
            ? String(localized: "含代金券 CNY \((voucher ?? 0).formatted(.number.precision(.fractionLength(2))))")
            : nil
        return ProviderBalanceSnapshot(
            currency: "CNY",
            available: available,
            used: nil,
            total: nil,
            isUnlimited: false,
            detailNote: note,
            source: .moonshot,
            fetchedAt: now
        )
    }

    private static func fetchOpenAICompatibleBilling(
        baseComponents: URLComponents,
        apiKey: String,
        headers: [CustomHeader],
        session: URLSession,
        now: Date
    ) async throws -> ProviderBalanceSnapshot {
        var rootComp = baseComponents
        rootComp.query = nil
        rootComp.fragment = nil
        var basePath = rootComp.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        if basePath.lowercased().hasSuffix("/v1") {
            basePath = String(basePath.dropLast(3))
        }

        var subComp = rootComp
        subComp.path = basePath + "/v1/dashboard/billing/subscription"
        guard let subURL = subComp.url else { throw ProviderBalanceError.unsupportedEndpoint }

        let subData = try await getJSONData(url: subURL, apiKey: apiKey, headers: headers, session: session)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -99, to: now) ?? now.addingTimeInterval(-99 * 86400)
        let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)

        var usageComp = rootComp
        usageComp.path = basePath + "/v1/dashboard/billing/usage"
        usageComp.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: start)),
            URLQueryItem(name: "end_date", value: formatter.string(from: end))
        ]
        let usageData: Data? = if let usageURL = usageComp.url {
            try? await getJSONData(url: usageURL, apiKey: apiKey, headers: headers, session: session)
        } else {
            nil
        }

        return try parseOpenAICompatibleBilling(subscriptionData: subData, usageData: usageData, now: now)
    }

    static func parseOpenAICompatibleBilling(
        subscriptionData: Data,
        usageData: Data?,
        now: Date = Date()
    ) throws -> ProviderBalanceSnapshot {
        guard let sub = try? JSONSerialization.jsonObject(with: subscriptionData) as? [String: Any] else {
            throw ProviderBalanceError.invalidResponse
        }
        let hardLimit = doubleValue(sub["hard_limit_usd"]) ?? doubleValue(sub["system_hard_limit_usd"])
        guard let hardLimit else {
            throw ProviderBalanceError.invalidResponse
        }
        let isUnlimited = hardLimit >= 99_999_999
        var usedUSD: Double? = nil
        if let usageData,
           let usageObj = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any],
           let totalUsageCents = doubleValue(usageObj["total_usage"]) {
            usedUSD = max(0, totalUsageCents / 100.0)
        }
        let available: Double? = if isUnlimited {
            nil
        } else if let usedUSD {
            hardLimit - usedUSD
        } else {
            hardLimit
        }
        return ProviderBalanceSnapshot(
            currency: "USD",
            available: available,
            used: usedUSD,
            total: isUnlimited ? nil : hardLimit,
            isUnlimited: isUnlimited,
            detailNote: nil,
            source: .openAIBillingCompatible,
            fetchedAt: now
        )
    }

    // MARK: - HTTP Helper

    private static func getJSONData(
        url: URL,
        apiKey: String,
        headers: [CustomHeader],
        session: URLSession
    ) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        LLMClient.applyCustomHeaders(headers, to: &req)

        let (bytes, response) = try await session.bytes(for: req, delegate: SameOriginRedirectDelegate.shared)
        defer { bytes.task.cancel() }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderBalanceError.invalidResponse
        }
        let maxBytes = 256 * 1024
        var body = Data()
        for try await b in bytes {
            guard body.count < maxBytes else { throw ProviderBalanceError.invalidResponse }
            body.append(b)
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = extractErrorMessage(from: body)
            throw ProviderBalanceError.httpStatus(http.statusCode, detail)
        }
        return body
    }

    private static func extractErrorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return String(msg.prefix(120))
            }
            if let msg = obj["message"] as? String {
                return String(msg.prefix(120))
            }
        }
        return ""
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double, d.isFinite { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Double(trimmed), d.isFinite { return d }
        }
        return nil
    }
}

/// Session-only in-memory cache of queried provider balances (never persisted to disk).
@MainActor
@Observable
final class ProviderBalanceStore {
    static let shared = ProviderBalanceStore()

    private(set) var snapshots: [UUID: ProviderBalanceSnapshot] = [:]
    private(set) var loadingIDs: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    @ObservationIgnored private var digests: [UUID: String] = [:]

    private init() {}

    private static func credentialDigest(provider: ProviderConfig, overrideKey: String? = nil) -> String {
        let key = LLMClient.sanitizedAPIKey(overrideKey ?? provider.apiKey)
        let raw = "\(provider.protocolRaw)|\(provider.baseURL)|\(key)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func snapshot(for provider: ProviderConfig, overrideKey: String? = nil) -> ProviderBalanceSnapshot? {
        guard digests[provider.id] == Self.credentialDigest(provider: provider, overrideKey: overrideKey) else {
            return nil
        }
        return snapshots[provider.id]
    }

    func refresh(provider: ProviderConfig, overrideKey: String? = nil) async {
        let id = provider.id
        let key = LLMClient.sanitizedAPIKey(overrideKey ?? provider.apiKey)
        let digest = Self.credentialDigest(provider: provider, overrideKey: key)
        loadingIDs.insert(id)
        errors[id] = nil
        defer { loadingIDs.remove(id) }

        do {
            let snap = try await ProviderBalanceService.fetchBalance(
                protocolType: provider.protocolType,
                baseURL: provider.baseURL,
                apiKey: key,
                customHeaders: provider.resolvedCustomHeaders
            )
            digests[id] = digest
            snapshots[id] = snap
            errors[id] = nil
        } catch is CancellationError {
            return
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    func clear(for providerID: UUID) {
        snapshots.removeValue(forKey: providerID)
        loadingIDs.remove(providerID)
        errors.removeValue(forKey: providerID)
        digests.removeValue(forKey: providerID)
    }
}
