import PDFKit
import SwiftUI

enum AttachmentSendFormat: String, CaseIterable {
    case original, text, both

    var label: LocalizedStringKey {
        switch self {
        case .original: "仅原件"
        case .text: "仅文字"
        case .both: "原件和文字"
        }
    }
}

struct DraftAttachmentReview: Identifiable {
    let id = UUID()
    let sources: [MessageAttachment]
    let recognize: Bool

    var isImages: Bool { sources.first?.kind == .image }
    var canIncludeOriginal: Bool { sources.allSatisfy { $0.dataBase64 != nil } }
    var defaultFormat: AttachmentSendFormat { recognize || !canIncludeOriginal ? .text : .original }

    func applying(_ format: AttachmentSendFormat, text: String, coverage: AttachmentTextCoverage?,
                  to current: [MessageAttachment]) throws -> [MessageAttachment] {
        guard let first = sources.first, sources.allSatisfy(current.contains) else { throw ReviewError.changed }
        let ids = Set(sources.map(\.id))
        func originalFile(_ item: MessageAttachment) -> MessageAttachment {
            guard item.kind == .document, item.mimeType == "application/pdf", item.dataBase64 != nil else { return item }
            var original = item
            original.extractedText = nil
            original.sendOriginalPDF = true
            return original
        }
        if format == .original { return current.map { ids.contains($0.id) ? originalFile($0) : $0 } }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= AttachmentProcessor.maxTextCharacters + 256 else { throw ReviewError.textLength }
        var file: MessageAttachment
        if isImages {
            file = DocumentOCRService.makeOCRDocumentAttachment(text: body, sourceFileName: first.fileName, pageCount: sources.count)
        } else {
            file = first
            file.dataBase64 = nil
            file.sendOriginalPDF = nil
            file.extractedText = body
            file.byteSize = body.utf8.count
            if first.mimeType == "application/pdf" {
                file.fileName = (first.fileName as NSString).deletingPathExtension + ".txt"
                file.mimeType = "text/plain"
            }
            if format == .both { file.id = UUID() }
        }
        file.textCoverage = coverage
        var inserted = false
        var next: [MessageAttachment] = []
        for item in current {
            guard ids.contains(item.id) else { next.append(item); continue }
            if format == .both {
                next.append(originalFile(item))
            }
            if !inserted { next.append(file); inserted = true }
        }
        try AttachmentProcessor.validate(next)
        return next
    }

    enum ReviewError: LocalizedError {
        case changed, textLength
        var errorDescription: String? {
            switch self {
            case .changed: String(localized: "草稿附件已更改，请重新打开预览。")
            case .textLength: String(localized: "请输入有效的附件文字，最多约 20 万字。")
            }
        }
    }
}

struct DraftAttachmentReviewSheet: View {
    let review: DraftAttachmentReview
    let apply: (AttachmentSendFormat, String, AttachmentTextCoverage?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var format: AttachmentSendFormat
    @State private var bodyText: String
    @State private var coverage: AttachmentTextCoverage?
    @State private var isReading: Bool
    @State private var error: String?

    init(review: DraftAttachmentReview, apply: @escaping (AttachmentSendFormat, String, AttachmentTextCoverage?) throws -> Void) {
        self.review = review
        self.apply = apply
        _format = State(initialValue: review.defaultFormat)
        _bodyText = State(initialValue: review.sources.first?.extractedText ?? "")
        _coverage = State(initialValue: review.sources.first?.textCoverage)
        let file = review.sources.first
        _isReading = State(initialValue: review.isImages || (file?.mimeType == "application/pdf" && file?.extractedText == nil && file?.dataBase64 != nil))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(review.sources) { file in
                        if let image = file.cachedImage {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                                .accessibilityLabel(Text(verbatim: file.fileName))
                        } else {
                            LabeledContent(file.fileName, value: file.formattedSize)
                            if file.mimeType == "application/pdf", let encoded = file.dataBase64 {
                                NavigationLink("查看 PDF 原件") { DraftPDFOriginal(encoded: encoded) }
                            }
                        }
                    }
                }
                if review.canIncludeOriginal {
                    Section {
                        Picker("随消息发送", selection: $format) {
                            ForEach(AttachmentSendFormat.allCases, id: \.self) { value in Text(value.label).tag(value) }
                        }
                    }
                }
                Section("提取的文字") {
                    if isReading { ProgressView("正在本地识别文字…") }
                    else {
                        if let coverage {
                            Text("共 \(coverage.totalPages) 页，\(coverage.pagesWithText) 页有文字，\(coverage.ocrPages) 页使用 OCR。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if coverage.isTruncated { Text("部分内容超过提取上限。").font(.footnote).foregroundStyle(.secondary) }
                        }
                        if bodyText.isEmpty { Text("未提取到文字，可手动补充。").font(.footnote).foregroundStyle(.secondary) }
                        TextEditor(text: Binding(get: { bodyText }, set: {
                            bodyText = $0
                            if format == .original { format = .text }
                        }))
                            .frame(minHeight: 160)
                            .accessibilityLabel("校对附件文字")

                    }
                }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            .navigationTitle("附件预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        do { try apply(format, bodyText, coverage); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(format != .original && (isReading || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .task {
                if let pdf = review.sources.first, pdf.mimeType == "application/pdf", pdf.extractedText == nil,
                   let base64 = pdf.dataBase64 {
                    let work = Task.detached(priority: .userInitiated) {
                        guard base64.utf8.count <= (ShareInputLoader.maximumSharedPDFBytes + 2) / 3 * 4,
                              let data = Data(base64Encoded: base64) else { return (text: "", coverage: Optional<AttachmentTextCoverage>.none) }
                        return AttachmentProcessor.extractPDFText(from: data)
                    }
                    let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
                    guard !Task.isCancelled else { return }
                    bodyText = result.text
                    coverage = result.coverage
                    isReading = false
                    return
                }
                guard review.isImages else { return }
                let result = await DocumentOCRService.convertImageAttachmentsToOCRDocument(review.sources)
                guard !Task.isCancelled else { return }
                bodyText = result.document?.extractedText ?? ""
                coverage = result.document?.textCoverage ?? AttachmentTextCoverage(totalPages: review.sources.count,
                    pagesWithText: 0, ocrPages: review.sources.count, isTruncated: false)
                isReading = false
            }
        }
    }
}

private struct DraftPDFOriginal: View {
    let encoded: String
    @State private var document: PDFDocument?
    @State private var loaded = false

    var body: some View {
        Group {
            if let document { DocumentPDFView(document: document) }
            else if loaded { ContentUnavailableView("无法预览文件", systemImage: "doc.questionmark") }
            else { ProgressView() }
        }
        .navigationTitle("查看 PDF 原件")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if encoded.utf8.count <= (AttachmentProcessor.maxInlinePDFBytes + 2) / 3 * 4,
               let data = Data(base64Encoded: encoded) { document = PDFDocument(data: data) }
            loaded = true
        }
    }
}
