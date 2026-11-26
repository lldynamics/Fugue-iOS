import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

struct QRCodeImportSheet: View {
    let onDecodedPayload: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var errorMessage: String?

    private var canUseLiveCameraScanner: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.lg) {
                if canUseLiveCameraScanner {
                    LiveQRCodeScannerRepresentable { scanned in
                        handleDecoded(scanned)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                            .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: 340)
                    .padding(.horizontal, DS.Spacing.md)
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("当前设备环境不支持实时相机扫码")
                            .font(.headline)
                        Text("你仍可直接从手机相册选择包含 API 配置的二维码截图进行本地解析。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(DS.Spacing.xl)
                    .frame(maxWidth: .infinity)
                    .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                    .padding(.horizontal, DS.Spacing.md)
                }

                VStack(spacing: DS.Spacing.sm) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("从相册选择二维码截图", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(DS.StatusText.error)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("支持解析包含 API Key、接口地址、JSON 配置或一键导入链接的二维码，图像全程仅在本机离线识别。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)

                Spacer(minLength: 0)
            }
            .padding(.top, DS.Spacing.md)
            .background(DS.Surface.grouped)
            .navigationTitle("扫码导入连接配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task { await decodePhotoItem(newItem) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func handleDecoded(_ raw: String) {
        if onDecodedPayload(raw) {
            errorMessage = nil
            dismiss()
        } else {
            errorMessage = String(localized: "二维码中未识别到有效的服务商地址或 API Key。")
        }
    }

    @MainActor
    private func decodePhotoItem(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let cgImage = image.cgImage else {
            errorMessage = String(localized: "无法读取所选图片，请重试。")
            return
        }
        let payloads = Self.extractQRPayloads(from: cgImage)
        guard !payloads.isEmpty else {
            errorMessage = String(localized: "未在图片中检测到二维码。")
            return
        }
        for payload in payloads {
            if onDecodedPayload(payload) {
                errorMessage = nil
                dismiss()
                return
            }
        }
        errorMessage = String(localized: "二维码中未识别到有效的服务商地址或 API Key。")
    }

    nonisolated static func extractQRPayloads(from cgImage: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        let results = request.results ?? []
        return results.compactMap { $0.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct LiveQRCodeScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScanned: (String) -> Void
        private var hasDelivered = false

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliverFirst(from: addedItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliverFirst(from: [item], scanner: dataScanner)
        }

        private func deliverFirst(from items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !hasDelivered else { return }
            for item in items {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !payload.isEmpty {
                    hasDelivered = true
                    scanner.stopScanning()
                    onScanned(payload)
                    return
                }
            }
        }
    }
}
