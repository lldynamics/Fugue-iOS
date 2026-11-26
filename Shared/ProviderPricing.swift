import Foundation
import CoreFoundation

enum ModelPriceSource: String, Codable {
    case openAIStandard, openAIShortContext, openRouter, variableRoute, manual
}

/// USD per million text tokens, in the same units used by the request ledger.
struct ProviderPricing: Equatable {
    let input: Double
    let output: Double
    var cachedInput: Double?
    var cacheWrite: Double?
    let source: ModelPriceSource

    func apply(to model: inout ModelSpec) {
        model.inputPricePerMillion = input
        model.outputPricePerMillion = output
        model.cacheReadPricePerMillion = cachedInput
        model.cacheWritePricePerMillion = cacheWrite
        model.priceCurrency = "USD"
        model.priceSource = source
    }

    static func applyRouter(_ pricing: [String: Any], to model: inout ModelSpec) {
        func number(_ key: String) -> Double? {
            if let text = pricing[key] as? String { return Double(text) }
            guard let value = pricing[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        func perMillion(_ key: String) -> Double? {
            number(key).flatMap { RequestRecord.validPrice($0 * 1_000_000) }
        }
        if number("prompt") == -1 || number("completion") == -1 {
            model.priceSource = .variableRoute
            return
        }
        guard let input = perMillion("prompt"), let output = perMillion("completion") else { return }
        ProviderPricing(input: input, output: output, cachedInput: perMillion("input_cache_read"),
                        cacheWrite: perMillion("input_cache_write"), source: .openRouter).apply(to: &model)
    }

    private static let publicSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Manual lookup also works for keys that may chat but cannot list account models.
    static func publishedModel(id: String, baseURL: String, session: URLSession = publicSession) async throws -> ModelSpec? {
        if URLComponents(string: baseURL)?.host?.lowercased() == "api.openai.com" {
            let prices = try await fetchOpenAI(session: session)
            guard let price = prices[id] else { return nil }
            var model = ModelSpec(id: id)
            price.apply(to: &model)
            return model
        }
        guard OpenAICompatibleAdapter.isOpenRouter(baseURL) else { return nil }
        let directory = try await OpenAICompatibleAdapter.fetchModels(baseURL: "https://openrouter.ai/api/v1",
                                                                     apiKey: "", customHeaders: [], session: session)
        return directory.first { $0.id == id && $0.priceSource != nil }
    }

    static func fetchOpenAI(session: URLSession) async throws -> [String: ProviderPricing] {
        // Public documentation. Start a fresh request so provider headers never leave the API endpoint.
        var request = URLRequest(url: URL(string: "https://developers.openai.com/api/docs/pricing.md")!)
        request.timeoutInterval = 6
        let data = try await ModelListTransport.boundedData(for: request, session: session, maximumBytes: 512 * 1024)
        return openAIStandardTable(String(decoding: data, as: UTF8.self))
    }

    static func openAIStandardTable(_ markdown: String) -> [String: ProviderPricing] {
        var result: [String: ProviderPricing] = [:]
        var inStandard = false
        var columns: [String] = []
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if inStandard { break }
                inStandard = line.lowercased() == "### standard pricing data"
                continue
            }
            guard inStandard, line.hasPrefix("|") else {
                columns = []
                continue
            }
            let cells = line.dropFirst().split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = cells.first else { continue }
            if first == "Model" {
                columns = cells.map { $0.lowercased() }
                continue
            }
            let tiered = columns.contains("short context input")
            func price(_ name: String) -> Double? {
                let heading = tiered ? "short context " + name : name
                guard let index = columns.firstIndex(of: heading), index < cells.count,
                      cells[index].hasPrefix("$") else { return nil }
                return RequestRecord.validPrice(Double(cells[index].dropFirst()))
            }
            guard let input = price("input"), let output = price("output"),
                  let id = first.split(separator: " ").first,
                  id.wholeMatch(of: #/[a-z0-9][a-z0-9._-]*/#) != nil else { continue }
            result[String(id)] = ProviderPricing(input: input, output: output, cachedInput: price("cached input"),
                                                 source: tiered ? .openAIShortContext : .openAIStandard)
        }
        return result
    }
}
