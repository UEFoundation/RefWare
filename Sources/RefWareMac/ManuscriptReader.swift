#if os(macOS)
import AppKit
import Foundation

public enum ManuscriptReadError: Error, CustomStringConvertible {
    case pages
    public var description: String { "Pages files can't be read directly — File ▸ Export To ▸ Word… and use the .docx" }
}

/// Plain text of a manuscript. Word/RTF/ODT/HTML go through AppKit's
/// converters (one line per paragraph); text and Markdown are read as-is.
public func readManuscript(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let types: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "rtfd": .rtfd, "odt": .openDocument,
        "html": .html, "htm": .html, "webarchive": .webArchive,
    ]
    let ext = url.pathExtension.lowercased()
    if ext == "pages" {
        throw ManuscriptReadError.pages
    }
    guard let type = types[ext] else { return try String(contentsOf: url, encoding: .utf8) }
    let doc = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    // Word soft line breaks (U+2028) and paragraph separators → newlines.
    return doc.string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
}

#endif
