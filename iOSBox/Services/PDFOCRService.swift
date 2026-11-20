import Foundation
import PDFKit
import UIKit
import Vision

enum PDFOCRService {
    private static let targetMaxDimension: CGFloat = 2000.0

    /// Performs offline Vision text recognition on a PDF page when no selectable text layer exists.
    /// Tiny synthetic pages (<60pt) are skipped immediately, and oversized mediaBoxes are downscaled
    /// so bitmap allocation stays strictly bounded.
    static func recognizeText(on page: PDFPage) -> String {
        guard !Task.isCancelled else { return "" }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width >= 60, bounds.height >= 60,
              bounds.width.isFinite, bounds.height.isFinite else { return "" }

        return autoreleasepool {
            let isQuarterTurn = abs(page.rotation) % 180 == 90
            let orientedWidth = isQuarterTurn ? bounds.height : bounds.width
            let orientedHeight = isQuarterTurn ? bounds.width : bounds.height
            let longest = max(orientedWidth, orientedHeight)
            guard longest > 0 else { return "" }

            // Scale small pages up (at most 2x) for legibility, and scale huge pages DOWN so the
            // longest pixel edge never exceeds `targetMaxDimension` (~16 MB RGBA ceiling).
            let scale = min(2.0, targetMaxDimension / longest)
            let targetSize = CGSize(
                width: max(1, min(targetMaxDimension, ceil(orientedWidth * scale))),
                height: max(1, min(targetMaxDimension, ceil(orientedHeight * scale)))
            )

            // `PDFPage.thumbnail(of:for:)` natively honors page rotation and non-zero mediaBox origins.
            let thumbnail = page.thumbnail(of: targetSize, for: .mediaBox)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1.0
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: thumbnail.size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: thumbnail.size))
                thumbnail.draw(at: .zero)
            }

            guard !Task.isCancelled, let cgImage = rendered.cgImage else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return ""
            }
        }
    }
}
