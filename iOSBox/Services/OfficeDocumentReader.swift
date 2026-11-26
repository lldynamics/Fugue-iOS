import Foundation
import ZIPFoundation

/// Parses Office Open XML documents (.docx, .xlsx, .pptx) securely inside an isolated ZIP + XMLParser pass
/// without executing macros, external DTDs, or resolving external entities.
enum OfficeDocumentReader {
    static let supportedExtensions: Set<String> = ["docx", "xlsx", "pptx"]
    static let legacyBinaryExtensions: Set<String> = ["doc", "xls", "ppt"]

    private static let maxExpandedBytes = 64 * 1_024 * 1_024
    private static let maxEntryCount = 40_000
    private static let xmlEntryLimit = 16 * 1_024 * 1_024
    private static let maxXMLDepth = 128
    private static let maxSheets = 200
    private static let maxRowsPerSheet = 5_000
    private static let maxColsPerRow = 64

    static func extractText(
        from data: Data,
        ext: String,
        fallbackTitle: String,
        maxCharacters: Int = 80_000
    ) throws -> String {
        let manuscript = try extractChapters(from: data, ext: ext, fallbackTitle: fallbackTitle)
        let body: String
        if manuscript.chapters.count == 1,
           manuscript.chapters[0].title == "正文" || manuscript.chapters[0].title == "Content" {
            body = manuscript.chapters[0].text
        } else {
            body = manuscript.chapters
                .map { "--- \($0.title) ---\n\($0.text)" }
                .joined(separator: "\n\n")
        }
        guard body.count > maxCharacters else { return body }
        let prefix = body.prefix(maxCharacters)
        return String(localized: "\(prefix)\n\n...[文档内容较长，已截取前 \(maxCharacters) 个字符]...")
    }

    static func extractChapters(
        from data: Data,
        ext: String,
        fallbackTitle: String
    ) throws -> BookManuscript {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw BookImportError.invalidBook }
        let lowerExt = ext.lowercased()
        guard supportedExtensions.contains(lowerExt) else { throw BookImportError.fileType }

        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw BookImportError.invalidBook
        }

        var entries: [String: Entry] = [:]
        for entry in archive where entry.type == .file {
            try Task.checkCancellation()
            guard entries.count < maxEntryCount, entries.updateValue(entry, forKey: entry.path) == nil else {
                throw BookImportError.invalidBook
            }
        }

        if entries["EncryptedPackage"] != nil {
            throw BookImportError.locked
        }

        var expanded = 0
        func readOptional(_ path: String, limit: Int = xmlEntryLimit) throws -> Data? {
            guard let entry = entries[path] else { return nil }
            guard entry.uncompressedSize <= UInt64(limit),
                  entry.uncompressedSize <= UInt64(max(0, maxExpandedBytes - expanded)) else {
                throw BookImportError.textLimit
            }
            var result = Data()
            let crc = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= limit - result.count,
                      chunk.count <= maxExpandedBytes - expanded else {
                    throw BookImportError.textLimit
                }
                result.append(chunk)
                expanded += chunk.count
            }
            guard UInt64(result.count) == entry.uncompressedSize, crc == entry.checksum else {
                throw BookImportError.invalidBook
            }
            return result
        }

        func readRequired(_ path: String, limit: Int = xmlEntryLimit) throws -> Data {
            guard let bytes = try readOptional(path, limit: limit) else {
                throw BookImportError.invalidBook
            }
            return bytes
        }

        let cleanTitle = String(
            fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300)
        )
        let resolvedTitle = cleanTitle.isEmpty ? String(localized: "未命名文档") : cleanTitle

        switch lowerExt {
        case "docx":
            return try readDocx(readRequired: readRequired, readOptional: readOptional, title: resolvedTitle)
        case "xlsx":
            return try readXlsx(entries: Array(entries.keys), readOptional: readOptional, title: resolvedTitle)
        case "pptx":
            return try readPptx(entries: Array(entries.keys), readOptional: readOptional, title: resolvedTitle)
        default:
            throw BookImportError.fileType
        }
    }

    private static func readDocx(
        readRequired: (String, Int) throws -> Data,
        readOptional: (String, Int) throws -> Data?,
        title: String
    ) throws -> BookManuscript {
        let rootRels = try readOptional("_rels/.rels", xmlEntryLimit).map {
            try parseRels($0, basePart: "")
        } ?? []
        let mainPath = rootRels.first {
            $0.type.lowercased().hasSuffix("/officedocument")
        }?.target ?? "word/document.xml"

        let mainText = try parseWordXML(try readRequired(mainPath, xmlEntryLimit))
        let docDir = mainPath.contains("/") ? String(mainPath[..<mainPath.lastIndex(of: "/")!]) : ""
        let notesPath = docDir.isEmpty ? "footnotes.xml" : "\(docDir)/footnotes.xml"
        let notesText = try readOptional(notesPath, xmlEntryLimit).map { try parseWordXML($0) } ?? ""

        var combined = mainText
        if !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !combined.isEmpty { combined += "\n\n" }
            combined += String(localized: "[脚注]\n") + notesText
        }
        combined = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { throw BookImportError.noText }
        guard combined.utf8.count <= BookManuscript.maximumTextBytes else { throw BookImportError.textLimit }
        let chapters: [BookChapter]
        do {
            chapters = try BookImporter.splitChapters(combined)
        } catch BookImportError.noText {
            chapters = [BookChapter(title: title, text: combined)]
        }
        return BookManuscript(title: title, chapters: chapters)
    }

    private static func readXlsx(
        entries: [String],
        readOptional: (String, Int) throws -> Data?,
        title: String
    ) throws -> BookManuscript {
        let sharedStrings = try readOptional("xl/sharedStrings.xml", xmlEntryLimit).map {
            try parseSharedStrings($0)
        } ?? []

        let workbookRels: [String: RelationshipEntry] = try readOptional("xl/_rels/workbook.xml.rels", xmlEntryLimit).map { data in
            var map: [String: RelationshipEntry] = [:]
            for rel in try parseRels(data, basePart: "xl/workbook.xml") {
                map[rel.id] = rel
            }
            return map
        } ?? [:]

        let declaredSheets = try readOptional("xl/workbook.xml", xmlEntryLimit).map {
            try parseWorkbookSheets($0)
        } ?? []

        var sheetTargets: [(name: String, path: String)] = declaredSheets.compactMap { sheet in
            guard let rel = workbookRels[sheet.relId] else { return nil }
            return (sheet.name, rel.target)
        }
        if sheetTargets.isEmpty {
            sheetTargets = entries.compactMap { path -> (Int, String, String)? in
                guard let num = trailingNumber(matching: "^xl/worksheets/sheet(\\d+)\\.xml$", in: path) else { return nil }
                return (num, String(localized: "工作表 \(num)"), path)
            }
            .sorted { $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
        }
        guard !sheetTargets.isEmpty else { throw BookImportError.noText }

        var chapters: [BookChapter] = []
        var totalBytes = 0
        for (sheetName, path) in sheetTargets.prefix(maxSheets) {
            try Task.checkCancellation()
            guard let sheetBytes = try readOptional(path, xmlEntryLimit) else { continue }
            let cleanSheetName = String(
                sheetName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            )
            let chapterTitle = cleanSheetName.isEmpty ? String(localized: "工作表") : cleanSheetName
            let remainingSheetBudget = BookManuscript.maximumTextBytes - totalBytes - chapterTitle.utf8.count
            guard remainingSheetBudget > 0 else { throw BookImportError.textLimit }
            let sheetText = try parseWorksheetXML(
                sheetBytes,
                sharedStrings: sharedStrings,
                maxOutputBytes: remainingSheetBudget
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sheetText.isEmpty else { continue }
            let added = chapterTitle.utf8.count + sheetText.utf8.count
            guard added <= BookManuscript.maximumTextBytes - totalBytes else { throw BookImportError.textLimit }
            totalBytes += added
            chapters.append(BookChapter(title: chapterTitle, text: sheetText))
        }
        guard !chapters.isEmpty else { throw BookImportError.noText }
        return BookManuscript(title: title, chapters: chapters)
    }

    private static func readPptx(
        entries: [String],
        readOptional: (String, Int) throws -> Data?,
        title: String
    ) throws -> BookManuscript {
        let presentationRels: [String: RelationshipEntry] = try readOptional("ppt/_rels/presentation.xml.rels", xmlEntryLimit).map { data in
            var map: [String: RelationshipEntry] = [:]
            for rel in try parseRels(data, basePart: "ppt/presentation.xml") {
                map[rel.id] = rel
            }
            return map
        } ?? [:]

        let orderedRelIds = try readOptional("ppt/presentation.xml", xmlEntryLimit).map {
            try parsePresentationSlideRelIds($0)
        } ?? []

        var slidePaths = orderedRelIds.compactMap { presentationRels[$0]?.target }
        if slidePaths.isEmpty {
            slidePaths = entries.compactMap { path -> (Int, String)? in
                guard let num = trailingNumber(matching: "^ppt/slides/slide(\\d+)\\.xml$", in: path) else { return nil }
                return (num, path)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
        }
        guard !slidePaths.isEmpty else { throw BookImportError.noText }
        guard slidePaths.count <= BookManuscript.maximumChapters else { throw BookImportError.textLimit }

        var chapters: [BookChapter] = []
        var totalBytes = 0

        for (index, slidePath) in slidePaths.enumerated() {
            try Task.checkCancellation()
            guard let slideBytes = try readOptional(slidePath, xmlEntryLimit) else { continue }
            let slideBody = try parsePresentationTextXML(slideBytes, ignoreSlideNumbers: false)

            let slideDir = slidePath.contains("/") ? String(slidePath[..<slidePath.lastIndex(of: "/")!]) : ""
            let slideFile = slidePath.split(separator: "/").last.map(String.init) ?? slidePath
            let relsPath = slideDir.isEmpty ? "_rels/\(slideFile).rels" : "\(slideDir)/_rels/\(slideFile).rels"
            let noteTarget = try readOptional(relsPath, xmlEntryLimit).flatMap { data in
                try parseRels(data, basePart: slidePath).first {
                    $0.type.lowercased().hasSuffix("/notesslide")
                }?.target
            } ?? "ppt/notesSlides/notesSlide\(index + 1).xml"

            let notesText = try readOptional(noteTarget, xmlEntryLimit).map {
                try parsePresentationTextXML($0, ignoreSlideNumbers: true)
            } ?? ""

            var combined = slideBody
            if !notesText.isEmpty {
                if !combined.isEmpty { combined += "\n\n" }
                combined += String(localized: "[备注] ") + notesText
            }
            combined = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combined.isEmpty else { continue }

            let chapterTitle = String(localized: "第 \(index + 1) 页")
            let added = chapterTitle.utf8.count + combined.utf8.count
            guard added <= BookManuscript.maximumTextBytes - totalBytes else { throw BookImportError.textLimit }
            totalBytes += added
            chapters.append(BookChapter(title: chapterTitle, text: combined))
        }

        guard !chapters.isEmpty else { throw BookImportError.noText }
        return BookManuscript(title: title, chapters: chapters)
    }

    static func resolvePackagePath(_ target: String, relativeTo basePart: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\\"),
              let parts = URLComponents(string: trimmed),
              parts.scheme == nil, parts.host == nil,
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              !decoded.isEmpty else { return nil }

        var components: [String]
        if decoded.hasPrefix("/") {
            components = []
        } else {
            components = basePart.split(separator: "/").dropLast().map(String.init)
        }
        for segment in decoded.drop(while: { $0 == "/" }).split(separator: "/") {
            if segment == "." || segment.isEmpty { continue }
            if segment == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(String(segment))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private struct RelationshipEntry {
        let id: String
        let type: String
        let target: String
    }

    private struct WorkbookSheetSpec {
        let name: String
        let relId: String
    }

    private static func trailingNumber(matching pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[groupRange])
    }

    private static func parseRels(_ data: Data, basePart: String) throws -> [RelationshipEntry] {
        var list: [RelationshipEntry] = []
        try parseXML(data) { name, attrs in
            guard name == "relationship" else { return }
            if attr(attrs, "TargetMode")?.lowercased() == "external" { return }
            guard let id = attr(attrs, "Id"),
                  let rawTarget = attr(attrs, "Target"),
                  let resolved = resolvePackagePath(rawTarget, relativeTo: basePart) else { return }
            list.append(RelationshipEntry(id: id, type: attr(attrs, "Type") ?? "", target: resolved))
        }
        return list
    }

    private static func parseWordXML(_ data: Data) throws -> String {
        var lines: [String] = []
        var tableDepth = 0
        var cellDepth = 0
        var inParagraph = false
        var inTextRun = false
        var headingLevel = 0
        var paragraphBuf = ""
        var currentRowCells: [String]?
        var currentCellBuf = ""

        try parseXML(
            data,
            onStart: { name, attrs in
                switch name {
                case "tbl": tableDepth += 1
                case "tr": if tableDepth > 0 { currentRowCells = [] }
                case "tc":
                    if tableDepth > 0 {
                        cellDepth += 1
                        if cellDepth == 1 { currentCellBuf = "" }
                    }
                case "p":
                    inParagraph = true
                    headingLevel = 0
                    paragraphBuf = ""
                case "pstyle":
                    if inParagraph, let rawStyle = attr(attrs, "val")?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        if let level = parseWordHeadingLevel(rawStyle) { headingLevel = level }
                    }
                case "t", "deltext":
                    if inParagraph { inTextRun = true }
                case "br":
                    if inParagraph { paragraphBuf.append("\n") }
                case "tab":
                    if inParagraph { paragraphBuf.append(" ") }
                default: break
                }
            },
            onChars: { str in
                if inParagraph && inTextRun { paragraphBuf += str }
            },
            onEnd: { name in
                switch name {
                case "t", "deltext": inTextRun = false
                case "p":
                    let rawPara = paragraphBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawPara.isEmpty {
                        let collapsed = rawPara.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        if cellDepth > 0 {
                            if !currentCellBuf.isEmpty { currentCellBuf += "; " }
                            currentCellBuf += collapsed
                        } else if (1...6).contains(headingLevel) {
                            let hashes = String(repeating: "#", count: min(headingLevel, 4))
                            lines.append("\(hashes) \(collapsed)")
                        } else {
                            lines.append(rawPara)
                        }
                    }
                    inParagraph = false
                    inTextRun = false
                    paragraphBuf = ""
                case "tc":
                    if cellDepth > 0 {
                        cellDepth -= 1
                        if cellDepth == 0 {
                            currentRowCells?.append(currentCellBuf.trimmingCharacters(in: .whitespacesAndNewlines))
                            currentCellBuf = ""
                        }
                    }
                case "tr":
                    if let row = currentRowCells, row.contains(where: { !$0.isEmpty }) {
                        lines.append(row.joined(separator: " | "))
                    }
                    currentRowCells = nil
                case "tbl":
                    if tableDepth > 0 { tableDepth -= 1 }
                default: break
                }
            }
        )
        return lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseWordHeadingLevel(_ style: String) -> Int? {
        let lower = style.lowercased()
        if lower.hasPrefix("heading") {
            let suffix = lower.dropFirst("heading".count).trimmingCharacters(in: .whitespaces)
            if let lvl = Int(suffix), (1...6).contains(lvl) { return lvl }
        }
        if style.hasPrefix("标题") {
            let suffix = style.dropFirst("标题".count).trimmingCharacters(in: .whitespaces)
            if let lvl = Int(suffix), (1...6).contains(lvl) { return lvl }
        }
        if let lvl = Int(lower), (1...6).contains(lvl) { return lvl }
        return nil
    }

    private static func parseSharedStrings(_ data: Data) throws -> [String] {
        var list: [String] = []
        var inSi = false
        var inPhonetic = false
        var inText = false
        var buf = ""

        try parseXML(
            data,
            onStart: { name, _ in
                switch name {
                case "si": inSi = true; buf = ""
                case "rph": if inSi { inPhonetic = true }
                case "t": if inSi && !inPhonetic { inText = true }
                default: break
                }
            },
            onChars: { str in
                if inSi && !inPhonetic && inText { buf += str }
            },
            onEnd: { name in
                switch name {
                case "t": inText = false
                case "rph": inPhonetic = false
                case "si":
                    list.append(buf)
                    inSi = false
                    inText = false
                default: break
                }
            }
        )
        return list
    }

    private static func parseWorkbookSheets(_ data: Data) throws -> [WorkbookSheetSpec] {
        var sheets: [WorkbookSheetSpec] = []
        try parseXML(data) { name, attrs in
            guard name == "sheet" else { return }
            let sheetName = attr(attrs, "name") ?? ""
            guard let relId = attr(attrs, "id") else { return }
            sheets.append(WorkbookSheetSpec(name: sheetName, relId: relId))
        }
        return sheets
    }

    private static func parseWorksheetXML(
        _ data: Data,
        sharedStrings: [String],
        maxOutputBytes: Int = BookManuscript.maximumTextBytes
    ) throws -> String {
        var rows: [String] = []
        var materializedBytes = 0
        var currentRowBytes = 0
        var cleanedSharedStrings = [String?](repeating: nil, count: sharedStrings.count)
        var inRow = false
        var rowLimitHit = false
        var currentRow: [(Int, String)] = []
        var nextCol = 0

        var inCell = false
        var cellCol = 0
        var cellType = ""
        var inValue = false
        var inInlineText = false
        var valBuf = ""

        let control = XMLParseControl()
        try parseXML(
            data,
            control: control,
            onStart: { name, attrs in
                switch name {
                case "row":
                    if rows.count >= maxRowsPerSheet {
                        rowLimitHit = true
                        control.stopCleanly()
                        return
                    }
                    inRow = true
                    currentRow = []
                    currentRowBytes = 0
                    nextCol = 0
                case "c":
                    if inRow {
                        inCell = true
                        cellCol = parseColumnIndex(attr(attrs, "r")) ?? nextCol
                        nextCol = cellCol + 1
                        cellType = (attr(attrs, "t") ?? "").lowercased()
                        valBuf = ""
                    }
                case "v":
                    if inCell && cellType != "inlinestr" {
                        inValue = true
                        valBuf = ""
                    }
                case "t":
                    if inCell && cellType == "inlinestr" {
                        inInlineText = true
                    }
                default: break
                }
            },
            onChars: { str in
                if inCell && (inValue || inInlineText) {
                    if str.utf8.count > maxOutputBytes - materializedBytes - currentRowBytes - valBuf.utf8.count {
                        control.abort(with: .textLimit)
                        return
                    }
                    valBuf += str
                }
            },
            onEnd: { name in
                switch name {
                case "v": inValue = false
                case "t": inInlineText = false
                case "c":
                    if inCell && cellCol >= 0 && cellCol < maxColsPerRow {
                        let raw = valBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                        let clean: String
                        switch cellType {
                        case "s":
                            if let idx = Int(raw), sharedStrings.indices.contains(idx) {
                                if let cached = cleanedSharedStrings[idx] {
                                    clean = cached
                                } else {
                                    let rawShared = sharedStrings[idx]
                                    if rawShared.utf8.count > maxOutputBytes {
                                        control.abort(with: .textLimit)
                                        return
                                    }
                                    let normalized = rawShared.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                                    cleanedSharedStrings[idx] = normalized
                                    clean = normalized
                                }
                            } else {
                                clean = ""
                            }
                        case "b":
                            if raw == "1" || raw.lowercased() == "true" { clean = "TRUE" }
                            else if raw.isEmpty { clean = "" }
                            else { clean = "FALSE" }
                        default:
                            clean = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        }
                        if !clean.isEmpty {
                            let cellUTF8 = clean.utf8.count + (currentRow.isEmpty ? 0 : 3)
                            if cellUTF8 > maxOutputBytes - materializedBytes - currentRowBytes {
                                control.abort(with: .textLimit)
                                return
                            }
                            currentRowBytes += cellUTF8
                            currentRow.append((cellCol, clean))
                        }
                    }
                    inCell = false
                    inValue = false
                    inInlineText = false
                case "row":
                    if inRow && !currentRow.isEmpty {
                        let maxCol = min(currentRow.map(\.0).max() ?? 0, maxColsPerRow - 1)
                        var dense = Array(repeating: "", count: maxCol + 1)
                        for (col, val) in currentRow where col <= maxCol {
                            dense[col] = val
                        }
                        let rowLine = dense.joined(separator: " | ")
                        let addedRowBytes = rowLine.utf8.count + (rows.isEmpty ? 0 : 1)
                        if addedRowBytes > maxOutputBytes - materializedBytes {
                            control.abort(with: .textLimit)
                            return
                        }
                        materializedBytes += addedRowBytes
                        rows.append(rowLine)
                    }
                    currentRow = []
                    currentRowBytes = 0
                    inRow = false
                default: break
                }
            }
        )
        if rowLimitHit {
            rows.append(String(localized: "…[工作表超过 \(maxRowsPerSheet) 行，已截断]…"))
        }
        return rows.joined(separator: "\n")
    }

    private static func parsePresentationSlideRelIds(_ data: Data) throws -> [String] {
        var ids: [String] = []
        try parseXML(data) { name, attrs in
            if name == "sldid", let id = attr(attrs, "id") {
                ids.append(id)
            }
        }
        return ids
    }

    private static func parsePresentationTextXML(_ data: Data, ignoreSlideNumbers: Bool) throws -> String {
        var paragraphs: [String] = []
        var inPara = false
        var inText = false
        var suppressedFieldDepth = 0
        var buf = ""

        try parseXML(
            data,
            onStart: { name, attrs in
                switch name {
                case "p":
                    inPara = true
                    buf = ""
                case "fld":
                    if inPara && ignoreSlideNumbers && attr(attrs, "type")?.lowercased() == "slidenum" {
                        suppressedFieldDepth += 1
                    }
                case "t":
                    if inPara && suppressedFieldDepth == 0 { inText = true }
                case "br":
                    if inPara && suppressedFieldDepth == 0 { buf.append("\n") }
                case "tab":
                    if inPara && suppressedFieldDepth == 0 { buf.append(" ") }
                default: break
                }
            },
            onChars: { str in
                if inPara && inText && suppressedFieldDepth == 0 { buf += str }
            },
            onEnd: { name in
                switch name {
                case "t": inText = false
                case "fld": if suppressedFieldDepth > 0 { suppressedFieldDepth -= 1 }
                case "p":
                    let clean = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { paragraphs.append(clean) }
                    inPara = false
                    inText = false
                default: break
                }
            }
        )
        return paragraphs.joined(separator: "\n")
    }

    private static func parseColumnIndex(_ ref: String?) -> Int? {
        guard let clean = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        var acc = 0
        var hasLetter = false
        for scalar in clean.unicodeScalars {
            let v = scalar.value
            if v >= 65 && v <= 90 {
                hasLetter = true
                acc = acc * 26 + Int(v - 64)
            } else if v >= 97 && v <= 122 {
                hasLetter = true
                acc = acc * 26 + Int(v - 96)
            } else {
                break
            }
        }
        return (hasLetter && acc >= 1) ? acc - 1 : nil
    }

    private static func attr(_ attrs: [String: String], _ name: String) -> String? {
        if let exact = attrs[name] { return exact }
        let target = name.lowercased()
        for (key, value) in attrs {
            let local = key.split(separator: ":").last?.lowercased() ?? key.lowercased()
            if local == target { return value }
        }
        return nil
    }

    private static func parseXML(
        _ data: Data,
        control: XMLParseControl = XMLParseControl(),
        onStart: @escaping (String, [String: String]) -> Void,
        onChars: @escaping (String) -> Void = { _ in },
        onEnd: @escaping (String) -> Void = { _ in }
    ) throws {
        try Task.checkCancellation()
        let probe = String(decoding: data.prefix(8_192), as: UTF8.self).uppercased()
        if probe.contains("<!ENTITY") || probe.contains("<!DOCTYPE") {
            throw BookImportError.invalidBook
        }
        let parser = XMLParser(data: data)
        control.bind(parser)
        let delegate = OOXMLParserDelegate(control: control, onStart: onStart, onChars: onChars, onEnd: onEnd)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let succeeded = parser.parse()
        if let customError = control.abortError {
            throw customError
        }
        if control.stoppedCleanly {
            try Task.checkCancellation()
            return
        }
        guard succeeded, parser.parserError == nil, !delegate.aborted else {
            try Task.checkCancellation()
            throw BookImportError.invalidBook
        }
    }
}

private final class XMLParseControl {
    private weak var parser: XMLParser?
    private(set) var abortError: BookImportError?
    private(set) var stoppedCleanly = false

    func bind(_ parser: XMLParser) {
        self.parser = parser
    }

    func abort(with error: BookImportError) {
        guard abortError == nil else { return }
        abortError = error
        parser?.abortParsing()
    }

    func stopCleanly() {
        guard abortError == nil else { return }
        stoppedCleanly = true
        parser?.abortParsing()
    }
}

private final class OOXMLParserDelegate: NSObject, XMLParserDelegate {
    private let control: XMLParseControl
    private let onStart: (String, [String: String]) -> Void
    private let onChars: (String) -> Void
    private let onEnd: (String) -> Void
    private var depth = 0
    private(set) var aborted = false

    init(
        control: XMLParseControl,
        onStart: @escaping (String, [String: String]) -> Void,
        onChars: @escaping (String) -> Void,
        onEnd: @escaping (String) -> Void
    ) {
        self.control = control
        self.onStart = onStart
        self.onChars = onChars
        self.onEnd = onEnd
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard control.abortError == nil, !control.stoppedCleanly else { return }
        depth += 1
        guard depth <= 128, !Task.isCancelled else {
            aborted = true
            parser.abortParsing()
            return
        }
        let name = elementName.split(separator: ":").last?.lowercased() ?? ""
        onStart(name, attributeDict)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !aborted, control.abortError == nil, !control.stoppedCleanly, !Task.isCancelled else {
            if control.abortError == nil && !control.stoppedCleanly {
                aborted = true
                parser.abortParsing()
            }
            return
        }
        onChars(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard control.abortError == nil, !control.stoppedCleanly else { return }
        let name = elementName.split(separator: ":").last?.lowercased() ?? ""
        onEnd(name)
        if depth > 0 { depth -= 1 }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        aborted = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        aborted = true
        parser.abortParsing()
    }
}
