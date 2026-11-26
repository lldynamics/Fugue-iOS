import Foundation
import JavaScriptCore
import SwiftUI
import Testing
import UIKit
@testable import iOSBox

struct AuditP1LocalizationShareAndDocsTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - 1. ReadingInput Non-Image vs Image Default Prompts

    @Test("ReadingInput uses text analysis prompt for plain-text, webpage, and PDF shares, and image prompt only when an image is present")
    func readingInputDistinguishesImageAndNonImageDefaultPrompts() throws {
        let expectedImagePrompt = String(localized: "请描述并分析这张图片。")
        let expectedContentPrompt = String(localized: "请总结并分析这段内容。")

        // Plain-text share in .ask mode with no custom question
        let textInput = ReadingInput(text: "Swift 6 strict concurrency notes")
        #expect(!textInput.hasImageAttachment)
        let textDisplay = textInput.displayPrompt(action: .ask, language: "English", question: "")
        #expect(textDisplay.hasPrefix(expectedContentPrompt))
        #expect(!textDisplay.contains(expectedImagePrompt))

        // Webpage share in .ask mode with no custom question
        let webInput = ReadingInput(
            text: "Full article body from Safari.",
            url: URL(string: "https://example.com/post"),
            title: "Example Post"
        )
        #expect(!webInput.hasImageAttachment)
        let webDisplay = webInput.displayPrompt(action: .ask, language: "简体中文", question: "   ")
        #expect(webDisplay.hasPrefix(expectedContentPrompt))
        #expect(!webDisplay.contains(expectedImagePrompt))

        // Document-only (PDF) share with empty text
        let pdfAttachment = MessageAttachment(
            kind: .document,
            fileName: "Spec.pdf",
            mimeType: "application/pdf",
            dataBase64: "JVBERi0xLjQK",
            byteSize: 10
        )
        let docInput = ReadingInput(text: "", attachments: [pdfAttachment])
        #expect(!docInput.hasImageAttachment)
        #expect(try docInput.prompt(action: .summarize, language: "English") == expectedContentPrompt)
        #expect(try docInput.prompt(action: .ask, language: "English", question: "") == expectedContentPrompt)
        #expect(docInput.displayPrompt(action: .ask, language: "English", question: "") == expectedContentPrompt)
        #expect(!docInput.displayPrompt(action: .translate, language: "English").contains("图片"))

        // Image share with empty text keeps the vision prompt
        let imageAttachment = MessageAttachment(
            kind: .image,
            fileName: "photo.jpg",
            mimeType: "image/jpeg",
            dataBase64: "AA==",
            byteSize: 2
        )
        let imageInput = ReadingInput(text: "", attachments: [imageAttachment])
        #expect(imageInput.hasImageAttachment)
        #expect(try imageInput.prompt(action: .summarize, language: "English") == expectedImagePrompt)
        #expect(try imageInput.prompt(action: .ask, language: "English", question: "") == expectedImagePrompt)
        #expect(imageInput.displayPrompt(action: .ask, language: "English", question: "") == expectedImagePrompt)

        // Custom question always overrides the default instruction
        #expect(try docInput.prompt(action: .ask, language: "English", question: "What is the deadline?") == "What is the deadline?")
        #expect(textInput.displayPrompt(action: .ask, language: "English", question: "Key risks?").hasPrefix("Key risks?"))
    }

    // MARK: - 2. DocumentOCRService Localized Errors & DSBadge Overloads

    @Test("DocumentOCRError provides non-empty localized error descriptions and DSBadge accepts both literals and runtime strings")
    func documentOCRErrorDescriptionsAndDSBadgeOverloads() {
        for err in DocumentOCRError.allCases {
            let desc = err.errorDescription ?? ""
            #expect(!desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(err.localizedDescription == desc)
        }

        #expect(throws: DocumentOCRError.invalidImage) {
            _ = try DocumentOCRService.recognizeRequiredText(in: UIImage())
        }

        // Compile-time & runtime verification that DSBadge supports both LocalizedStringKey literals and String values
        let literalBadge = DSBadge(text: "命中目标短语", icon: "sparkles", style: .accent(.teal))
        let runtimeText = String("v1.0")
        let verbatimBadge = DSBadge(text: runtimeText, style: .neutral)
        _ = (literalBadge, verbatimBadge)
    }

    // MARK: - 3. ExtractPage.js Hidden/Tiny Article Fallback & Code Indentation

    private func evaluateExtractPage(domSetupJS: String) throws -> [String: Any] {
        let scriptURL = repoRoot.appendingPathComponent("iOSBoxShare/ExtractPage.js")
        let extractScript = try String(contentsOf: scriptURL, encoding: .utf8)

        let context = try #require(JSContext())
        var jsException: String?
        context.exceptionHandler = { _, exception in
            jsException = exception?.toString()
        }

        let harness = """
        function makeText(val) {
            return { nodeType: 3, nodeValue: String(val), textContent: String(val) };
        }
        function makeEl(tag, opts, children) {
            opts = opts || {};
            var kids = children || [];
            var attrs = opts.attrs || {};
            var el = {
                nodeType: 1,
                tagName: String(tag).toUpperCase(),
                hidden: !!opts.hidden,
                style: opts.style || {},
                computedStyle: opts.computedStyle || null,
                childNodes: kids,
                parentElement: null,
                parentNode: null,
                getAttribute: function (name) {
                    return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
                }
            };
            Object.defineProperty(el, "textContent", {
                get: function () {
                    return el.childNodes.map(function (c) { return c.textContent || ""; }).join("");
                }
            });
            for (var i = 0; i < kids.length; i++) {
                kids[i].parentElement = el;
                kids[i].parentNode = el;
            }
            el.querySelectorAll = function (selector) {
                var parts = String(selector).split(",").map(function (s) { return s.trim(); });
                var matches = [];
                function matchesSingle(node, sel) {
                    if (sel === "[role='main']" || sel === '[role="main"]') {
                        return node.getAttribute("role") === "main";
                    }
                    return node.tagName === sel.toUpperCase();
                }
                function walk(n) {
                    for (var j = 0; j < n.childNodes.length; j++) {
                        var child = n.childNodes[j];
                        if (child.nodeType === 1) {
                            for (var p = 0; p < parts.length; p++) {
                                if (matchesSingle(child, parts[p])) {
                                    matches.push(child);
                                    break;
                                }
                            }
                            walk(child);
                        }
                    }
                }
                walk(el);
                return matches;
            };
            el.querySelector = function (selector) {
                var all = el.querySelectorAll(selector);
                return all.length > 0 ? all[0] : null;
            };
            return el;
        }
        var window = {
            location: { href: "https://example.com/article" },
            getSelection: function () { return ""; },
            getComputedStyle: function (el) {
                if (el && el.computedStyle) return el.computedStyle;
                return {
                    display: (el && el.style && el.style.display) || "block",
                    visibility: (el && el.style && el.style.visibility) || "visible"
                };
            }
        };
        """

        context.evaluateScript(harness)
        #expect(jsException == nil, "DOM harness failed: \(jsException ?? "")")

        context.evaluateScript(domSetupJS)
        #expect(jsException == nil, "DOM setup failed: \(jsException ?? "")")

        context.evaluateScript(extractScript)
        #expect(jsException == nil, "ExtractPage.js load failed: \(jsException ?? "")")

        let runner = """
        var __captured = null;
        ExtensionPreprocessingJS.run({
            completionFunction: function (payload) { __captured = payload; }
        });
        __captured;
        """
        let result = context.evaluateScript(runner)
        #expect(jsException == nil, "ExtractPage.js execution failed: \(jsException ?? "")")
        return try #require(result?.toDictionary() as? [String: Any])
    }

    @Test("ExtractPage.js ignores hidden or tiny widget articles and falls back to main/body")
    func extractPageSkipsHiddenAndTinyArticles() throws {
        let longParagraph = String(repeating: "Substantive engineering analysis of SwiftUI localization behavior. ", count: 4)
        let hiddenAndTinyDOM = """
        var body = makeEl("body", {}, [
            makeEl("nav", {}, [makeText("Site Navigation")]),
            makeEl("article", { hidden: true }, [
                makeEl("p", {}, [makeText("Hidden modal promo that must never be extracted — " + \(String(reflecting: longParagraph)))])
            ]),
            makeEl("article", { attrs: { "aria-hidden": "true" } }, [
                makeEl("p", {}, [makeText("Aria-hidden carousel banner")])
            ]),
            makeEl("article", { attrs: { "style": "display: none" } }, [
                makeEl("p", {}, [makeText("Inline display-none teaser")])
            ]),
            makeEl("article", {}, [
                makeEl("p", {}, [makeText("Tiny sidebar card")])
            ]),
            makeEl("main", {}, [
                makeEl("h1", {}, [makeText("Real Main Heading")]),
                makeEl("p", {}, [makeText(\(String(reflecting: longParagraph)))])
            ]),
            makeEl("footer", {}, [makeText("Copyright Footer")])
        ]);
        var html = makeEl("html", {}, [body]);
        var document = {
            title: "Architecture Post",
            URL: "https://example.com/architecture",
            body: body,
            documentElement: html,
            querySelectorAll: function (s) { return html.querySelectorAll(s); },
            querySelector: function (s) { return html.querySelector(s); }
        };
        """

        let payload = try evaluateExtractPage(domSetupJS: hiddenAndTinyDOM)
        let extractedText = try #require(payload["text"] as? String)
        #expect(extractedText.contains("Real Main Heading"))
        #expect(extractedText.contains("Substantive engineering analysis"))
        #expect(!extractedText.contains("Hidden modal promo"))
        #expect(!extractedText.contains("Aria-hidden carousel"))
        #expect(!extractedText.contains("Inline display-none"))
        #expect(!extractedText.contains("Site Navigation"))
        #expect(!extractedText.contains("Copyright Footer"))
    }

    @Test("ExtractPage.js preserves indentation and internal spacing inside pre and code blocks")
    func extractPagePreservesPreAndCodeIndentation() throws {
        let codeBlock = """
        def render_tree(node):
            if node is None:
                return "empty   leaf"

            for child in node.children:
                \tprint(child)
        """
        let codeDOM = """
        var body = makeEl("body", {}, [
            makeEl("article", {}, [
                makeEl("h1", {}, [makeText("Code   Formatting   Guide")]),
                makeEl("p", {}, [
                    makeText("Normal   prose    collapses   spaces, while "),
                    makeEl("code", {}, [makeText("inline   code")]),
                    makeText("   keeps them. " + \(String(reflecting: String(repeating: "Extra context sentence for article threshold. ", count: 3))))
                ]),
                makeEl("pre", {}, [
                    makeEl("code", {}, [makeText(\(String(reflecting: codeBlock)))])
                ])
            ])
        ]);
        var html = makeEl("html", {}, [body]);
        var document = {
            title: "Code Guide",
            URL: "https://example.com/code",
            body: body,
            documentElement: html,
            querySelectorAll: function (s) { return html.querySelectorAll(s); },
            querySelector: function (s) { return html.querySelector(s); }
        };
        """

        let payload = try evaluateExtractPage(domSetupJS: codeDOM)
        let text = try #require(payload["text"] as? String)

        #expect(text.contains("Code Formatting Guide"))
        #expect(text.contains("Normal prose collapses spaces, while inline   code keeps them."))
        #expect(text.contains("    if node is None:\n        return \"empty   leaf\""))
        #expect(text.contains("\n\n    for child in node.children:\n        \tprint(child)"))
    }

    // MARK: - 4. Documentation & Ternary Localization Consistency Checks

    @Test("App Store docs and data interoperability spec match onboarding button labels, formats, and v8 memoryCollections")
    func documentationAndLocalizationConsistency() throws {
        let listing = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/app-store/app-store-listing.md"),
            encoding: .utf8
        )
        let support = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/app-store/support.md"),
            encoding: .utf8
        )
        let checklist = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/app-store/submission-checklist.md"),
            encoding: .utf8
        )
        let interop = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/data-interoperability.md"),
            encoding: .utf8
        )

        for (name, doc) in [("app-store-listing.md", listing), ("support.md", support), ("submission-checklist.md", checklist)] {
            #expect(!doc.contains("使用此模型"), "\(name) still references stale button label 使用此模型")
            #expect(!doc.contains("Use this model"), "\(name) still references stale button label Use this model")
            #expect(doc.contains("保存并继续"), "\(name) must reference 保存并继续")
        }

        #expect(listing.contains("Save and Continue"))
        #expect(support.contains("Save and Continue"))
        #expect(support.contains("资料库 → 书架"))
        #expect(support.contains("Library → Bookshelf"))
        #expect(listing.contains("DOCX") && listing.contains("XLSX") && listing.contains("PPTX"))
        #expect(support.contains("DOCX") && support.contains("XLSX") && support.contains("PPTX"))

        #expect(interop.contains("`memoryCollections`"))
        #expect(interop.contains("WebDAV"))
        #expect(interop.contains("restoreMemoryCollections") || interop.contains("主动省略 `memoryCollections`"))

        // Guard against unlocalized SwiftUI ternary string literals regressing in the three audited sheets
        let auditedSheets = [
            "iOSBox/Views/Chat/AudioTranscriptionSheet.swift",
            "iOSBox/Views/Chat/BookmarksHubSheet.swift",
            "iOSBox/Views/English/EnglishRoleplaySheetView.swift"
        ]
        let rawTernaryPattern = try NSRegularExpression(pattern: #"\?\s*"[^"]*[\u4e00-\u9fff][^"]*"\s*:\s*"[^"]*[\u4e00-\u9fff][^"]*""#)
        for relPath in auditedSheets {
            let source = try String(contentsOf: repoRoot.appendingPathComponent(relPath), encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            #expect(rawTernaryPattern.firstMatch(in: source, range: range) == nil, "Found raw unlocalized Chinese ternary in \(relPath)")
        }
    }
}
