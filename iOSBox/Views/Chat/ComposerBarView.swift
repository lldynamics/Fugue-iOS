import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerBarView: View {
    @Bindable var conversation: Conversation
    @Binding var draftText: String
    @Binding var pendingAttachments: [MessageAttachment]
    let isGenerating: Bool
    let onOpenModelPicker: () -> Void
    let onOpenArenaPicker: () -> Void
    let onOpenSettings: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showFileImporter = false
    @State private var attachmentError: String?

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            // Quick control strip: Model switcher + Arena toggle + Chat parameters
            HStack(spacing: 8) {
                Button {
                    if conversation.isArenaMode {
                        onOpenArenaPicker()
                    } else {
                        onOpenModelPicker()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if conversation.isArenaMode {
                            Image(systemName: "square.split.2x1.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text("并发对比 · \(max(conversation.arenaTargets.count, 0)) 模型")
                                .font(.caption.weight(.semibold))
                        } else if let target = conversation.primaryTarget {
                            Circle()
                                .fill(Color(hex: target.accentHex))
                                .frame(width: 7, height: 7)
                            Text(target.modelDisplayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        } else {
                            Image(systemName: "cpu")
                                .font(.caption2)
                            Text("选择模型")
                                .font(.caption.weight(.semibold))
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    if conversation.isArenaMode {
                        withAnimation(.snappy(duration: 0.2)) {
                            conversation.isArenaMode = false
                        }
                    } else {
                        onOpenArenaPicker()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.caption2)
                        Text(conversation.isArenaMode ? "退出对比" : "多模型对比")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(conversation.isArenaMode ? Color.accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        conversation.isArenaMode
                            ? Color.accentColor.opacity(0.14)
                            : Color(.secondarySystemBackground),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: 4) {
                        Text(conversation.assistantEmoji)
                            .font(.caption)
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)

            // Pending attachments preview strip
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { item in
                            pendingAttachmentChip(item)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            // Input row
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("从相册选择图片", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showCameraPicker = true
                    } label: {
                        Label("拍照识图", systemImage: "camera")
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("上传文档或代码文件", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .padding(.bottom, 3)
                }

                TextField("输入消息，支持随时切换模型或发图…", text: $draftText, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if isGenerating {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 31))
                            .foregroundStyle(.red)
                            .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 31))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.35))
                            .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 4,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let attachment = AttachmentProcessor.processImageData(data, suggestedName: "photo_\(Int(Date().timeIntervalSince1970)).jpg") {
                        await MainActor.run {
                            pendingAttachments.append(attachment)
                        }
                    }
                }
                await MainActor.run {
                    selectedPhotoItems.removeAll()
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView { image in
                if let attachment = AttachmentProcessor.processImage(image, fileName: "camera_\(Int(Date().timeIntervalSince1970)).jpg") {
                    pendingAttachments.append(attachment)
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .json, .commaSeparatedText, .xml, .sourceCode, .data, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do {
                        let att = try AttachmentProcessor.processFileURL(url)
                        pendingAttachments.append(att)
                    } catch {
                        attachmentError = "读取文件失败：\(error.localizedDescription)"
                    }
                }
            case .failure(let error):
                attachmentError = error.localizedDescription
            }
        }
        .alert("附件提示", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("确定", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    @ViewBuilder
    private func pendingAttachmentChip(_ item: MessageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            if item.kind == .image,
               let b64 = item.dataBase64,
               let data = Data(base64Encoded: b64),
               let uiImg = UIImage(data: data) {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: item.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.fileName)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                        Text(item.formattedSize)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 48)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                pendingAttachments.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.68))
            }
            .offset(x: 5, y: -5)
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}
