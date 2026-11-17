import XCTest
@testable import iOSBox

/// English localization and SwiftMath rendering.
final class LocalizationTests: XCTestCase {

    private var englishBundle: Bundle {
        get throws {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"), "app must ship en.lproj")
            return try XCTUnwrap(Bundle(path: path))
        }
    }

    private func english(_ key: String) throws -> String {
        try englishBundle.localizedString(forKey: key, value: "⚠️MISSING", table: nil)
    }

    func testAppShipsEnglishAndChineseLocalizations() throws {
        XCTAssertTrue(Bundle.main.localizations.contains("en"))
        XCTAssertTrue(Bundle.main.localizations.contains("zh-Hans"))
        XCTAssertEqual(Bundle.main.developmentLocalization, "en", "languages other than zh/en fall back to English")

        // Chinese must have its own table; otherwise iOS falls back to the English one.
        let zhPath = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let zh = try XCTUnwrap(Bundle(path: zhPath))
        XCTAssertEqual(zh.localizedString(forKey: "新对话", value: "⚠️MISSING", table: nil), "新对话")
        XCTAssertEqual(zh.localizedString(forKey: "停止生成", value: "⚠️MISSING", table: nil), "停止生成")
    }

    func testRepresentativeStringsAreTranslated() throws {
        XCTAssertEqual(try english("新对话"), "New Chat")
        XCTAssertEqual(try english("服务商"), "Providers")
        XCTAssertEqual(try english("停止生成"), "Stop Generating")
        XCTAssertEqual(try english("OpenAI 兼容协议"), "OpenAI-Compatible")
        XCTAssertEqual(try english("全能日常助手"), "Everyday Assistant")
    }

    func testFormatStringsKeepTheirPlaceholders() throws {
        XCTAssertEqual(String(format: try english("最近 %lld 条"), 20), "Last 20")
        XCTAssertEqual(String(format: try english("模型列表（已启用 %lld/%lld）"), 3, 10), "Models (3/10 enabled)")
        XCTAssertEqual(String(format: try english("请先在「服务商」页面为「%@」配置 API Key（本地服务若免鉴权可忽略）"), "DeepSeek"),
                       "Add an API key for “DeepSeek” on the Providers tab first (not needed for local services without auth)")
    }

    func testEnglishInfoPlistPermissionStrings() throws {
        let path = try XCTUnwrap(try englishBundle.path(forResource: "InfoPlist", ofType: "strings"))
        let strings = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        XCTAssertEqual(strings["NSCameraUsageDescription"], "Used to take photos and send them to AI models for analysis.")
        XCTAssertNotNil(strings["NSLocalNetworkUsageDescription"])
    }

    /// The compiled English table must cover the catalog (completeness against the compiler-
    /// extracted keys is enforced by scripts/generate_string_catalogs.py) and contain no
    /// leftover Chinese text.
    func testCompiledEnglishTableIsCompleteAndChineseFree() throws {
        let path = try XCTUnwrap(try englishBundle.path(forResource: "Localizable", ofType: "strings"))
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        XCTAssertGreaterThan(table.count, 250)

        let chinese = try NSRegularExpression(pattern: "[\\u4e00-\\u9fff]")
        let leftovers = table.filter { _, value in
            chinese.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        XCTAssertEqual(leftovers.keys.sorted(), [], "English values containing Chinese")
    }
}

@MainActor
final class MathRenderingTests: XCTestCase {

    func testValidLaTeXRendersAndInvalidReturnsNil() throws {
        let inline = try XCTUnwrap(MathRenderer.render(latex: "E = mc^2", fontSize: 17, colorScheme: .light, displayStyle: false))
        XCTAssertGreaterThan(inline.image.size.width, 0)
        XCTAssertGreaterThanOrEqual(inline.descent, 0)

        let fraction = try XCTUnwrap(MathRenderer.render(latex: "\\frac{1}{3}", fontSize: 17, colorScheme: .dark, displayStyle: true))
        XCTAssertGreaterThan(fraction.descent, 0, "a fraction extends below the baseline")

        XCTAssertNil(MathRenderer.render(latex: "\\frac{1}{2", fontSize: 17, colorScheme: .light, displayStyle: true))
        XCTAssertNil(MathRenderer.render(latex: "   ", fontSize: 17, colorScheme: .light, displayStyle: true))
    }

    func testInlineMathSplitting() {
        XCTAssertEqual(InlineMathParser.split("质能方程 $E=mc^2$ 成立"), [.text("质能方程 "), .math("E=mc^2", display: false), .text(" 成立")])
        XCTAssertEqual(InlineMathParser.split(#"而 \(\alpha\) 是"#), [.text("而 "), .math(#"\alpha"#, display: false), .text(" 是")])
        XCTAssertEqual(InlineMathParser.split("公式 $$x^2$$ 行内"), [.text("公式 "), .math("x^2", display: true), .text(" 行内")])
    }

    func testCurrencyCodeAndEscapesStayText() {
        for text in ["价格是 $5 和 $10。", "costs $3.50 per $1M", "`echo $HOME$`", #"转义 \$x\$ 不是公式"#, "$ x$"] {
            let segments = InlineMathParser.split(text)
            XCTAssertFalse(segments.contains { if case .math = $0 { return true } else { return false } }, text)
        }
    }
}
