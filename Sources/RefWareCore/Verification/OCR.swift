import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif

/// Text recognition for scanned PDFs (pages that are images with no text layer),
/// using Apple's on-device Vision framework. Nothing leaves the machine.
enum OCR {
    static func lines(of page: PDFPage) -> [String] {
        #if canImport(Vision)
        guard let image = cgImage(of: page) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // Top to bottom, then left to right (two-column pages read column-by-column poorly, but titles/abstracts are fine).
        let obs = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        return obs.compactMap { $0.topCandidates(1).first?.string }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #else
        return []
        #endif
    }

    private static func cgImage(of page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5 // ~180 dpi for a letter page: good accuracy, reasonable speed
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        #if os(macOS)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return page.thumbnail(of: size, for: .mediaBox).cgImage
        #endif
    }
}
