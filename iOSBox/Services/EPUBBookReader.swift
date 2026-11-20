import Foundation
import ZIPFoundation

/// Reads only local publication documents in spine order. Book resources are never installed or rendered.
enum EPUBBookReader {
    static func read(_ data: Data, fallbackTitle: String) throws -> BookManuscript {
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw BookImportError.invalidBook }
        var entries: [String: Entry] = [:]
        for entry in archive where entry.type == .file {
            guard entries.count < 40_000, entries.updateValue(entry, forKey: entry.path) == nil else { throw BookImportError.invalidBook }
        }
        var expanded = 0
        func bytes(_ path: String, limit: Int) throws -> Data {
            guard let entry = entries[path] else { throw BookImportError.invalidBook }
            guard entry.uncompressedSize <= UInt64(limit) else { throw BookImportError.textLimit }
            var result = Data()
            let crc = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= limit - result.count, chunk.count <= 64 * 1_024 * 1_024 - expanded else { throw BookImportError.textLimit }
                result.append(chunk)
                expanded += chunk.count
            }
            guard UInt64(result.count) == entry.uncompressedSize, crc == entry.checksum else { throw BookImportError.invalidBook }
            return result
        }
        let container = try EPUBXML.parse(bytes("META-INF/container.xml", limit: 256 * 1_024), mode: .container)
        guard let package = container.rootFile, let opf = localPath(package, relativeTo: "") else { throw BookImportError.invalidBook }
        let manifest = try EPUBXML.parse(bytes(opf, limit: 4 * 1_024 * 1_024), mode: .package)
        var encrypted = Set<String>()
        if entries["META-INF/encryption.xml"] != nil {
            let info = try EPUBXML.parse(bytes("META-INF/encryption.xml", limit: 1_024 * 1_024), mode: .encryption)
            encrypted = Set(info.encryptedPaths.compactMap { localPath($0, relativeTo: "") })
        }
        var chapters: [BookChapter] = [], total = 0
        guard manifest.spine.count <= BookManuscript.maximumChapters else { throw BookImportError.textLimit }
        for id in manifest.spine {
            try Task.checkCancellation()
            guard let resource = manifest.manifest[id] else { throw BookImportError.invalidBook }
            guard ["application/xhtml+xml", "text/html"].contains(resource.type) else { continue }
            guard let path = localPath(resource.href, relativeTo: opf) else { throw BookImportError.invalidBook }
            guard !encrypted.contains(path) else { throw BookImportError.locked }
            let content = try bytes(path, limit: 24 * 1_024 * 1_024)
            let page = try EPUBXML.chapter(content)
            let text = page.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            total += text.utf8.count
            guard total <= BookManuscript.maximumTextBytes else { throw BookImportError.textLimit }
            let label = page.heading.isEmpty ? page.title : page.heading
            chapters.append(BookChapter(title: label.isEmpty ? String(localized: "第 \(chapters.count + 1) 节") : String(label.prefix(300)), text: text))
        }
        guard !chapters.isEmpty else { throw BookImportError.noText }
        return BookManuscript(title: manifest.title.isEmpty ? fallbackTitle : String(manifest.title.prefix(300)), chapters: chapters)
    }

    private static func localPath(_ href: String, relativeTo document: String) -> String? {
        guard let parts = URLComponents(string: href), parts.scheme == nil, parts.host == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding, !path.isEmpty,
              !path.hasPrefix("/"), !path.contains("\\") else { return nil }
        var result = document.split(separator: "/").dropLast().map(String.init)
        for component in path.split(separator: "/") {
            if component == ".." {
                guard !result.isEmpty else { return nil }
                result.removeLast()
            } else if component != "." { result.append(String(component)) }
        }
        return result.isEmpty ? nil : result.joined(separator: "/")
    }
}

private final class EPUBXML: NSObject, XMLParserDelegate {
    enum Mode { case container, package, encryption, chapter }
    struct Item { let href: String; let type: String }
    let mode: Mode
    private(set) var manifest: [String: Item] = [:], spine: [String] = [], encryptedPaths: [String] = []
    private(set) var rootFile: String?, title = "", heading = "", body = ""
    private var stack: [String] = [], suppressed = 0, bodyDepth: Int?, captureDepth: Int?, capture = "", captureHeading = false
    private var aborted = false
    private init(_ mode: Mode) { self.mode = mode }

    /// Some EPUB 2 files use HTML typographic entities defined in an external XHTML DTD.
    /// Resolve those common names locally, without fetching the publication's DTD.
    static func chapter(_ data: Data) throws -> EPUBXML {
        do { return try parse(data, mode: .chapter) }
        catch BookImportError.invalidBook {
            try Task.checkCancellation()
            guard var source = String(data: data, encoding: .utf8) else { throw BookImportError.invalidBook }
            let entities = ["nbsp": 160, "mdash": 8212, "ndash": 8211, "ldquo": 8220, "rdquo": 8221,
                            "lsquo": 8216, "rsquo": 8217, "hellip": 8230, "copy": 169]
            var changed = false
            for (name, code) in entities {
                let token = "&" + name + ";"
                if source.contains(token) {
                    source = source.replacingOccurrences(of: token, with: "&#" + String(code) + ";")
                    changed = true
                }
            }
            guard changed else { throw BookImportError.invalidBook }
            return try parse(Data(source.utf8), mode: .chapter)
        }
    }

    static func parse(_ data: Data, mode: Mode) throws -> EPUBXML {
        let delegate = EPUBXML(mode)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), parser.parserError == nil, !delegate.aborted else { throw BookImportError.invalidBook }
        return delegate
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String]) {
        let name = elementName.split(separator: ":").last?.lowercased() ?? ""
        stack.append(name)
        guard stack.count <= 128, !Task.isCancelled else { aborted = true; parser.abortParsing(); return }
        switch mode {
        case .container:
            if name == "rootfile", rootFile == nil { rootFile = attrs["full-path"] }
        case .encryption:
            if name == "cipherreference", let path = attrs["URI"] { encryptedPaths.append(path) }
        case .package:
            if name == "item", let id = attrs["id"], let href = attrs["href"], let type = attrs["media-type"] {
                manifest[id] = Item(href: href, type: type)
            } else if name == "itemref", attrs["linear"]?.lowercased() != "no", let id = attrs["idref"] { spine.append(id) }
            if name == "title", stack.contains("metadata"), title.isEmpty { beginCapture(heading: false) }
        case .chapter:
            if ["script", "style", "nav", "svg", "noscript"].contains(name) { suppressed += 1 }
            guard suppressed == 0 else { return }
            if name == "body" { bodyDepth = stack.count }
            if name == "title", stack.contains("head"), title.isEmpty { beginCapture(heading: false) }
            if ["h1", "h2"].contains(name), bodyDepth != nil, heading.isEmpty, captureDepth == nil { beginCapture(heading: true) }
            if bodyDepth != nil, ["br", "p", "div", "li", "section", "h1", "h2", "h3"].contains(name), !body.hasSuffix("\n") { body += "\n" }
        }
    }
    private func beginCapture(heading: Bool) { captureDepth = stack.count; captureHeading = heading; capture = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard suppressed == 0 else { return }
        if captureDepth != nil, capture.utf8.count < 1_200 { capture += string.prefix(300) }
        if bodyDepth != nil { body += string }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count == captureDepth {
            let clean = capture.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if captureHeading { heading = clean } else { title = clean }
            captureDepth = nil
        }
        if stack.count == bodyDepth { bodyDepth = nil }
        if mode == .chapter, let name = stack.last, ["script", "style", "nav", "svg", "noscript"].contains(name) { suppressed -= 1 }
        _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { aborted = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { aborted = true; parser.abortParsing() }
}
