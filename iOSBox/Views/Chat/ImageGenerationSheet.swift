import SwiftUI
import PhotosUI
import UIKit

struct ImageGenerationSheet: View {
    let providers: [ProviderConfig]
    let onInsertIntoChat: (String, MessageAttachment, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderID: UUID?
    @State private var modelID = "gpt-image-1"
    @State private var prompt = ""
    @State private var aspectSize: ImageAspectSize = .square
    @State private var selectedRefItem: PhotosPickerItem?
    @State private var referenceImage: UIImage?
    @State private var referenceImageData: Data?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generatedResult: GeneratedImageResult?
    @State private var generatedUIImage: UIImage?
    @State private var shareFileURL: URL?

    private var eligibleProviders: [ProviderConfig] {
        ImageGenerationService.eligibleProviders(from: providers)
    }

    private var selectedProvider: ProviderConfig? {
        eligibleProviders.first { $0.id == selectedProviderID } ?? eligibleProviders.first
    }

    var body: some View {
        NavigationStack {
            Form {
                if eligibleProviders.isEmpty {
                    Section {
                        Text("暂无可用的绘图服务商。请先在「设置」中配置 OpenAI 兼容（如 OpenAI / 硅基流动 / OneAPI）或 Google Gemini 服务商。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("服务商与模型") {
                        Picker("服务商", selection: Binding(
                            get: { selectedProvider?.id },
                            set: { newID in
                                selectedProviderID = newID
                                if let p = eligibleProviders.first(where: { $0.id == newID }),
                                   let firstSuggested = ImageGenerationService.suggestedModels(for: p.protocolType).first {
                                    modelID = firstSuggested
                                }
                            }
                        )) {
                            ForEach(eligibleProviders) { provider in
                                Text("\(provider.name) (\(provider.protocolType.shortBadge))").tag(Optional(provider.id))
                            }
                        }

                        TextField("模型 ID（如 gpt-image-1 / FLUX.1-schnell）", text: $modelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        if let proto = selectedProvider?.protocolType {
                            let suggestions = ImageGenerationService.suggestedModels(for: proto)
                            if !suggestions.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(suggestions, id: \.self) { candidate in
                                            Button {
                                                modelID = candidate
                                            } label: {
                                                Text(candidate)
                                                    .font(.caption2.monospaced())
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 5)
                                                    .background(
                                                        modelID == candidate ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                                                        in: Capsule()
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        if selectedProvider?.protocolType != .gemini {
                            Picker("画面比例", selection: $aspectSize) {
                                ForEach(ImageAspectSize.allCases) { size in
                                    Text(size.label).tag(size)
                                }
                            }
                        }
                    }

                    Section {
                        TextField("描述想要生成的画面，或上传参考图并输入修改指令…", text: $prompt, axis: .vertical)
                            .lineLimit(3...8)

                        HStack {
                            PhotosPicker(selection: $selectedRefItem, matching: .images) {
                                Label(referenceImage == nil ? "添加参考图（图生图 / 修图）" : "更换参考图", systemImage: "photo.badge.plus")
                                    .font(.subheadline)
                            }
                            if referenceImage != nil {
                                Spacer()
                                Button("移除", role: .destructive) {
                                    referenceImage = nil
                                    referenceImageData = nil
                                    selectedRefItem = nil
                                }
                                .font(.caption)
                            }
                        }

                        if let referenceImage {
                            Image(uiImage: referenceImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    } header: {
                        Text("提示词与参考图")
                    }

                    Section {
                        Button {
                            Task { await runGeneration() }
                        } label: {
                            HStack {
                                Spacer()
                                if isGenerating {
                                    ProgressView().controlSize(.small)
                                    Text("正在生成图片…")
                                } else {
                                    Label(referenceImage == nil ? "生成图片" : "开始修图 / 图生图", systemImage: "wand.and.stars")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    if let generatedUIImage, let result = generatedResult {
                        Section("生成结果") {
                            Image(uiImage: generatedUIImage)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            if let revised = result.revisedPrompt, !revised.isEmpty {
                                Text(revised)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                Button {
                                    insertGeneratedImage(result)
                                } label: {
                                    Label("插入当前对话", systemImage: "arrow.up.doc.on.clipboard")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                if let shareFileURL {
                                    ShareLink(item: shareFileURL) {
                                        Label("分享", systemImage: "square.and.arrow.up")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("AI 生图 / 修图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if selectedProviderID == nil, let first = eligibleProviders.first {
                    selectedProviderID = first.id
                    if let suggested = ImageGenerationService.suggestedModels(for: first.protocolType).first {
                        modelID = suggested
                    }
                }
            }
            .onChange(of: selectedRefItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImg = UIImage(data: data),
                       let pngData = uiImg.pngData() {
                        await MainActor.run {
                            referenceImage = uiImg
                            referenceImageData = pngData
                        }
                    }
                }
            }
        }
    }

    private func runGeneration() async {
        guard let provider = selectedProvider else { return }
        isGenerating = true
        errorMessage = nil
        generatedResult = nil
        generatedUIImage = nil
        shareFileURL = nil
        defer { isGenerating = false }

        let request = ImageGenerationRequest(
            providerName: provider.name,
            protocolType: provider.protocolType,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            apiKeys: provider.extraAPIKeys,
            customHeaders: provider.resolvedCustomHeaders,
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt,
            size: aspectSize,
            quality: "auto",
            referenceImageData: referenceImageData,
            referenceImageMimeType: referenceImageData == nil ? nil : "image/png"
        )
        do {
            let result = try await ImageGenerationService.generate(request)
            guard let img = UIImage(data: result.imageData) else {
                errorMessage = ImageGenerationError.invalidResponse.localizedDescription
                return
            }
            let ext = result.mimeType.contains("jpeg") ? "jpg" : "png"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fugue-Image-\(UUID().uuidString.prefix(8)).\(ext)")
            try? result.imageData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            generatedResult = result
            generatedUIImage = img
            shareFileURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func insertGeneratedImage(_ result: GeneratedImageResult) {
        let ext = result.mimeType.contains("jpeg") ? "jpg" : "png"
        let attachment = MessageAttachment(
            kind: .image,
            fileName: "generated-\(UUID().uuidString.prefix(6)).\(ext)",
            mimeType: result.mimeType,
            dataBase64: result.imageData.base64EncodedString(),
            extractedText: nil,
            byteSize: result.imageData.count
        )
        onInsertIntoChat(prompt.trimmingCharacters(in: .whitespacesAndNewlines), attachment, result.revisedPrompt)
        dismiss()
    }
}
