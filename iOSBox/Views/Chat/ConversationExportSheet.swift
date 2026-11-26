import PDFKit
import SwiftUI

struct ConversationExportSheet: View {
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var format = Format.markdown
    @State private var selectsMessages = false
    @State private var selected = Set<UUID>()
    @State private var options = ConversationExporter.Options()
    @State private var previewURL: URL?
    @State private var error: String?
    @State private var preparing = false

    private enum Format { case markdown, pdf, image }

    private var messages: [ChatMessage] {
        ConversationTree.activeMessages(in: conversation).filter {
            $0.role == .user || $0.role == .assistant || $0.assistanceMetadata.sourceNotice != nil || $0.assistanceMetadata.isContextDivider
        }
    }

    private var selectedIDs: Set<UUID> {
        Set(messages.filter { !selectsMessages || selected.contains($0.id) }.map(\.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("文件格式", selection: $format) {
                        Text(verbatim: "Markdown").tag(Format.markdown)
                        Text(verbatim: "PDF").tag(Format.pdf)
                        Text("分享长图").tag(Format.image)
                    }
                    .pickerStyle(.segmented)
                    Picker("导出范围", selection: $selectsMessages) {
                        Text("当前分支").tag(false)
                        Text("勾选消息").tag(true)
                    }
                    if selectsMessages {
                        ForEach(messages) { message in
                            Button {
                                if !selected.insert(message.id).inserted { selected.remove(message.id) }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(message.id) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(message.role == .user ? String(localized: "提问") : ArenaSynthesis.visibleSpeakerName(for: message))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(verbatim: message.content.isEmpty ? message.attachments.map(\.fileName).joined(separator: ", ") : message.content)
                                            .lineLimit(2).foregroundStyle(.primary)
                                    }
                                }
                            }
                            .accessibilityAddTraits(selected.contains(message.id) ? .isSelected : [])
                        }
                    }
                }
                if format == .image {
                    Section {
                        Text("长图展示所选范围最后 12 条有正文或附件的消息，每条正文最多 900 字。")
                        if let notice = ConversationExporter.shareCardContent(for: conversation, selectedIDs: selectedIDs).notice {
                            Text(verbatim: notice)
                        }
                    }
                } else {
                    Section("附加内容") {
                        Toggle("思考过程", isOn: $options.includesReasoning)
                        Toggle("系统提示词", isOn: $options.includesSystemPrompt)
                        Toggle("引文与来源", isOn: $options.includesReferences)
                    }
                }
                Section {
                    Button {
                        Task { await preparePreview() }
                    } label: {
                        if preparing { ProgressView() } else { Label("预览导出文件", systemImage: "doc.text.magnifyingglass") }
                    }
                    .disabled(messages.isEmpty || (selectsMessages && !messages.contains { selected.contains($0.id) }))
                    if let error { Text(error).foregroundStyle(DS.StatusText.error) }
                }
            }
            .disabled(preparing)
            .navigationTitle("分享与导出")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .navigationDestination(item: $previewURL) { url in ConversationExportPreview(url: url) }
        }
    }

    @MainActor
    private func preparePreview() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        error = nil
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        var selection = options
        selection.messageIDs = ids
        do {
            switch format {
            case .markdown:
                previewURL = try ConversationExporter.writeMarkdownFile(for: conversation, options: selection)
            case .pdf:
                previewURL = try await ConversationExporter.writePDFFile(for: conversation, options: selection)
            case .image:
                guard let url = try ConversationExporter.writeShareImageFile(for: conversation, colorScheme: colorScheme, selectedIDs: ids) else {
                    error = String(localized: "当前对话暂无可生成分享图的消息内容。")
                    return
                }
                previewURL = url
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct ConversationExportPreview: View {
    let url: URL
    @State private var contents: Contents?

    private enum Contents {
        case markdown(String), image(UIImage), pdf(PDFDocument), failed
    }

    var body: some View {
        Group {
            switch contents {
            case .markdown(let text):
                ScrollView { Text(verbatim: text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            case .image(let image):
                ScrollView { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("分享长图") }
            case .pdf(let document):
                DocumentPDFView(document: document)
            case .failed:
                ContentUnavailableView("无法预览文件", systemImage: "doc.questionmark")
            case nil: ProgressView()
            }
        }
        .navigationTitle("导出预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                switch contents {
                case .markdown, .image, .pdf:
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                default: EmptyView()
                }
            }
        }
        .task(id: url) {
            switch url.pathExtension {
            case "pdf": contents = PDFDocument(url: url).map(Contents.pdf) ?? .failed
            case "png": contents = UIImage(contentsOfFile: url.path).map(Contents.image) ?? .failed
            default: contents = (try? String(contentsOf: url, encoding: .utf8)).map(Contents.markdown) ?? .failed
            }
        }
    }
}

struct DocumentPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
