import Foundation
import CryptoKit

struct PersonaFeedItem: Equatable, Sendable {
    let id: String
    let title: String
    let url: URL
    var excerpt: String?
    var published: Date?
}

final class SubscriptionFeedParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var bases: [URL]
    private var sourceDepth: Int?
    private var field: String?
    private var fieldDepth = 0
    private var buffer = ""
    private var fields: [String: String] = [:]
    private var link: URL?
    private var recognized = false
    private var items: [PersonaFeedItem] = []
    private var seen = Set<String>()
    private let rssDate = DateFormatter()
    private let isoDate = ISO8601DateFormatter()

    private init(url: URL) {
        bases = [url]
        super.init()
        rssDate.locale = Locale(identifier: "en_US_POSIX")
        rssDate.timeZone = TimeZone(secondsFromGMT: 0)
        rssDate.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
    }

    static func parse(_ data: Data, url: URL) throws -> [PersonaFeedItem] {
        guard data.count <= URLReader.maximumBytes else { throw URLReaderError.tooLarge }
        let delegate = SubscriptionFeedParser(url: url)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), delegate.recognized else { throw PersonaError.invalidFeed }
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        let name = elementName.split(separator: ":").last?.lowercased() ?? ""
        stack.append(name)
        let parentURL = bases.last!
        bases.append(attrs["xml:base"].flatMap { URL(string: $0, relativeTo: parentURL)?.absoluteURL } ?? parentURL)
        if stack.count == 1 { recognized = ["rss", "feed", "rdf"].contains(name) }
        guard recognized, stack.count < 100 else { parser.abortParsing(); return }
        if sourceDepth == nil, stack == ["rss", "channel", "item"] || stack == ["feed", "entry"] || stack == ["rdf", "item"] {
            sourceDepth = stack.count
            fields = [:]
            link = nil
        } else if let depth = sourceDepth, stack.count == depth + 1 {
            field = name
            fieldDepth = stack.count
            buffer = ""
            if name == "link", ["alternate", ""].contains(attrs["rel"] ?? ""), let href = attrs["href"],
               let url = publicLink(href) { link = url }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil, buffer.utf8.count < 8192 { buffer += string.prefix(8192 - min(8192, buffer.utf8.count)) }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data.prefix(8192), as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let field, stack.count == fieldDepth {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                fields[field] = text
                if field == "link", link == nil { link = publicLink(text) }
            }
            self.field = nil
        }
        if let depth = sourceDepth, stack.count == depth {
            if let url = link ?? publicLink(fields["guid"] ?? fields["id"] ?? "") {
                let key = fields["guid"] ?? fields["id"] ?? url.absoluteString
                let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                if seen.insert(id).inserted {
                    let title = HTMLTextExtractor.plainText(fields["title"] ?? "")
                    let excerpt = HTMLTextExtractor.plainText(fields["summary"] ?? fields["description"] ?? fields["content"] ?? "")
                    let stamp = fields["published"] ?? fields["pubdate"] ?? fields["date"] ?? fields["updated"] ?? ""
                    let date = isoDate.date(from: stamp) ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)) ?? rssDate.date(from: stamp)
                    items.append(PersonaFeedItem(id: id, title: String((title.isEmpty ? url.absoluteString : title).prefix(350)),
                                                 url: url, excerpt: String(excerpt.prefix(350)), published: date))
                }
            }
            sourceDepth = nil
        }
        _ = stack.popLast()
        _ = bases.popLast()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }

    private func publicLink(_ value: String) -> URL? {
        guard !value.isEmpty, let url = URL(string: value, relativeTo: bases.last)?.absoluteURL,
              (try? URLReader.validate(url)) != nil else { return nil }
        return url
    }

    /// Discover the feed advertised by a blog homepage, including relative and entity-escaped hrefs.
    static func discover(in html: String, at base: URL) -> URL? {
        let head = String(html.prefix(150_000)).components(separatedBy: "</head>").first ?? ""
        let tags = try! NSRegularExpression(pattern: #"(?is)<link\b[^>]*>"#)
        let attrs = try! NSRegularExpression(pattern: #"(?is)\b(rel|type|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        let ns = head as NSString
        for tag in tags.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: tag.range) as NSString
            var values: [String: String] = [:]
            for match in attrs.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                if let range = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                    values[text.substring(with: match.range(at: 1)).lowercased()] = text.substring(with: range)
                }
            }
            guard values["rel"]?.lowercased().split(whereSeparator: \.isWhitespace).contains("alternate") == true,
                  ["application/rss+xml", "application/atom+xml"].contains(values["type"]?.lowercased() ?? ""),
                  let raw = values["href"], let url = URL(string: HTMLTextExtractor.decodeEntities(raw), relativeTo: base)?.absoluteURL,
                  (try? URLReader.validate(url)) != nil else { continue }
            return url
        }
        return nil
    }
}
