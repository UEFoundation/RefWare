import Foundation
import PDFKit

public enum PDFTextError: Error, CustomStringConvertible {
    case unreadable(URL)
    case noText(URL)

    public var description: String {
        switch self {
        case .unreadable(let url): "could not open PDF \(url.path)"
        case .noText(let url): "\(url.lastPathComponent) has no extractable text (scanned image?) — OCR it first"
        }
    }
}

public enum PDFText {
    /// OCR results are cached as `<file>.ocr.json` beside the PDF (OCR takes a few seconds a page).
    static func ocrPages(of doc: PDFDocument, url: URL) throws -> PageLines {
        let cache = url.isFileURL && url.path.hasSuffix(".pdf") ? url.deletingPathExtension().appendingPathExtension("ocr.json") : nil
        if let cache, let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(PageLines.self, from: data) {
            return cached
        }
        let pages = (0..<doc.pageCount).map { i in doc.page(at: i).map(OCR.lines(of:)) ?? [] }
        if let cache, pages.contains(where: { !$0.isEmpty }) {
            try? JSONEncoder().encode(pages).write(to: cache, options: .atomic)
        }
        return pages
    }

    /// Extracts each page's text as non-empty lines. Line numbers in quote
    /// records refer to these lines (the nth text line on the PDF page).
    public static func pages(of data: Data) throws -> PageLines {
        guard let doc = PDFDocument(data: data) else { throw PDFTextError.unreadable(URL(fileURLWithPath: "(downloaded PDF)")) }
        return try pages(of: doc, url: URL(fileURLWithPath: "(downloaded PDF)"))
    }

    public static func pages(of url: URL) throws -> PageLines {
        guard let doc = PDFDocument(url: url) else { throw PDFTextError.unreadable(url) }
        return try pages(of: doc, url: url)
    }

    static func pages(of doc: PDFDocument, url: URL) throws -> PageLines {
        var pages: PageLines = []
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            pages.append(text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        // Scanned PDF (no text layer): recognize the text on-device. Cached next to the PDF.
        if !pages.contains(where: { !$0.isEmpty }) {
            pages = try ocrPages(of: doc, url: url)
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw PDFTextError.noText(url) }
        return pages
    }
}
