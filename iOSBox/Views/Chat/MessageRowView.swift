import SwiftUI
import UIKit

struct MessageRowView: View {
    let message: ChatMessage
    var isCompactCard: Bool = false
    var onRegenerate: (() -> Void)?
    var onRegenerateWithCurrentModel: (() -> Void)?

    @State private var copiedToast = false
    @State private var previewImage: UIImage?

    var body: some View {
        if message.role == .user {
            userMessageView
        } else {
            assistantMessageView
        }
    }

    // MARK: - User Bubble

    private var userMessageView: some View {
        HStack {
            Spacer(minLength: 42)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.attachments.isEmpty {
                    attachmentGrid(message.attachments)
                }

                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(.white)
                        .lineSpacing(3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("复制提问", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
        }
        .sheet(item: Binding(
            get: { previewImage.map { IdentifiableImage(image: $0) } },
            set: { if $0 == nil { previewImage = nil } }
        )) { wrapper in
            ImageFullScreenSheet(image: wrapper.image)
        }
    }

    @ViewBuilder
    private func attachmentGrid(_ items: [MessageAttachment]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = items.filter { $0.kind == .image }
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { att in
                        if let b64 = att.dataBase64,
                           let data = Data(base64Encoded: b64),
                           let uiImg = UIImage(data: data) {
                            Button {
                                previewImage = uiImg
                            } label: {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 112, height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看图片 \(att.fileName)")
                        }
                    }
                }
            }

            ForEach(items.filter { $0.kind == .document }) { doc in
                HStack(spacing: 8) {
                    Image(systemName: doc.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.fileName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(doc.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Assistant Card

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isCompactCard {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color(hex: message.accentHex))
                        .frame(width: 9, height: 9)

                    Text(message.modelDisplayName.isEmpty ? String(localized: "AI 助手") : message.modelDisplayName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)

                    if !message.providerName.isEmpty {
                        Text(message.providerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }

                    Spacer()

                    if message.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }

            if !message.reasoningContent.isEmpty {
                ReasoningCardView(
                    reasoning: message.reasoningContent,
                    isActivelyThinking: message.isStreaming && message.content.isEmpty,
                    durationMs: message.thinkingDurationMs
                )
            }

            if !message.content.isEmpty {
                MarkdownContentView(text: message.content)
            } else if message.isStreaming && message.reasoningContent.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在连接模型生成回复…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            // Truncated / filtered answers that still have content (empty ones show as errors).
            if !message.isStreaming, !message.content.isEmpty, let reason = message.finishReasonValue {
                Label(reason.userNotice, systemImage: reason == .length ? "scissors" : "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let err = message.errorMessage, !err.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        if let onRegenerate {
                            Button("重试请求") {
                                onRegenerate()
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            if !message.isStreaming && (!message.content.isEmpty || message.errorMessage != nil) {
                HStack(spacing: 14) {
                    if !message.content.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.content
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            copiedToast = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                await MainActor.run { copiedToast = false }
                            }
                        } label: {
                            Label(copiedToast ? String(localized: "已复制") : String(localized: "复制"), systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(copiedToast ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if let onRegenerate {
                        Menu {
                            Button {
                                onRegenerate()
                            } label: {
                                Label(String(localized: "使用原模型重答 (\(message.modelDisplayName))"), systemImage: "arrow.clockwise")
                            }
                            if let onRegenerateWithCurrentModel {
                                Button {
                                    onRegenerateWithCurrentModel()
                                } label: {
                                    Label("使用当前顶部所选模型重答", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                        } label: {
                            Label("重答", systemImage: "arrow.clockwise")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    metricsBadge
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metricsBadge: some View {
        HStack(spacing: 8) {
            if let prompt = message.promptTokens, let comp = message.completionTokens {
                Text("\(prompt + comp) tok")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else if let comp = message.completionTokens {
                Text("\(comp) tok")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let ms = message.latencyMs, ms > 0 {
                Text(String(format: "%.1fs", Double(ms) / 1000.0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ImageFullScreenSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
