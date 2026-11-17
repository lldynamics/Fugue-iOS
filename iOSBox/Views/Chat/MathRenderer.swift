import SwiftUI
import UIKit
import SwiftMath

/// Typesets LaTeX with SwiftMath into images (cached), for display blocks and inline math.
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: UIImage
        /// Distance from the math baseline to the image bottom; used to align inline math
        /// with the surrounding text baseline.
        let descent: CGFloat
    }

    private final class Box {
        let value: Rendered?
        init(_ value: Rendered?) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    /// Returns nil when the LaTeX can't be parsed, so callers can fall back to source text.
    static func render(latex: String, fontSize: CGFloat, colorScheme: ColorScheme, displayStyle: Bool) -> Rendered? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = "\(displayStyle ? "D" : "T")|\(fontSize)|\(colorScheme == .dark ? "dark" : "light")|\(trimmed)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let label = MTMathUILabel()
        label.labelMode = displayStyle ? .display : .text
        label.textAlignment = .left
        label.fontSize = fontSize
        label.textColor = UIColor.label.resolvedColor(with: traits)
        label.displayErrorInline = false
        label.latex = trimmed

        var rendered: Rendered?
        let size = label.intrinsicContentSize
        if label.error == nil, size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite {
            label.frame = CGRect(origin: .zero, size: size)
            label.setNeedsLayout()
            label.layoutIfNeeded()
            if let displayList = label.displayList {
                let image = UIGraphicsImageRenderer(size: size).image { context in
                    // SwiftMath draws in a bottom-left origin coordinate space.
                    context.cgContext.translateBy(x: 0, y: size.height)
                    context.cgContext.scaleBy(x: 1, y: -1)
                    displayList.draw(context.cgContext)
                }
                rendered = Rendered(image: image, descent: displayList.descent)
            }
        }

        cache.setObject(Box(rendered), forKey: key)
        return rendered
    }
}

// MARK: - Inline math splitting

enum InlineMathSegment: Equatable {
    case text(String)
    case math(String, display: Bool)
}

enum InlineMathParser {
    /// Splits a paragraph into text and math segments.
    /// Recognizes `\( … \)`, `$$ … $$` and `$ … $`. For single `$`, the opening `$` must be
    /// followed by a non-space and the closing `$` preceded by a non-space and not followed by a
    /// digit, so prices like "$5 and $10" stay plain text. `\$` and code spans are left alone.
    static func split(_ text: String) -> [InlineMathSegment] {
        guard text.contains("$") || text.contains("\\(") else { return [.text(text)] }

        let chars = Array(text)
        var segments: [InlineMathSegment] = []
        var buffer = ""
        var i = 0

        func flush() {
            if !buffer.isEmpty {
                segments.append(.text(buffer))
                buffer = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            // Code span: copy verbatim up to the closing backtick.
            if c == "`" {
                if let close = chars[(i + 1)...].firstIndex(of: "`") {
                    buffer.append(contentsOf: chars[i...close])
                    i = close + 1
                    continue
                }
            }

            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "$" {
                    buffer.append(contentsOf: "\\$")
                    i += 2
                    continue
                }
                if next == "(", let close = find(["\\", ")"], in: chars, from: i + 2) {
                    let tex = String(chars[(i + 2)..<close])
                    if !tex.trimmingCharacters(in: .whitespaces).isEmpty {
                        flush()
                        segments.append(.math(tex, display: false))
                        i = close + 2
                        continue
                    }
                }
            }

            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$",
                   let close = find(["$", "$"], in: chars, from: i + 2) {
                    let tex = String(chars[(i + 2)..<close])
                    if !tex.trimmingCharacters(in: .whitespaces).isEmpty {
                        flush()
                        segments.append(.math(tex, display: true))
                        i = close + 2
                        continue
                    }
                }
                if let close = closingDollar(in: chars, openingAt: i) {
                    flush()
                    segments.append(.math(String(chars[(i + 1)..<close]), display: false))
                    i = close + 1
                    continue
                }
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return segments
    }

    private static func find(_ pattern: [Character], in chars: [Character], from start: Int) -> Int? {
        guard start <= chars.count - pattern.count else { return nil }
        var j = start
        while j <= chars.count - pattern.count {
            if Array(chars[j..<(j + pattern.count)]) == pattern { return j }
            j += 1
        }
        return nil
    }

    private static func closingDollar(in chars: [Character], openingAt open: Int) -> Int? {
        let first = open + 1
        guard first < chars.count, !chars[first].isWhitespace, chars[first] != "$" else { return nil }
        var j = first
        while j < chars.count {
            let c = chars[j]
            if c == "\n" { return nil } // inline math doesn't span lines
            if c == "\\" { j += 2; continue }
            if c == "$" {
                let precededBySpace = chars[j - 1].isWhitespace
                let followedByDigit = j + 1 < chars.count && chars[j + 1].isNumber
                if !precededBySpace && !followedByDigit && j > first {
                    return j
                }
                if precededBySpace { return nil }
            }
            j += 1
        }
        return nil
    }
}
