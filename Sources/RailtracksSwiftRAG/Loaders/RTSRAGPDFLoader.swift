//
//  RTSRAGPDFLoader.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation
import PDFKit

/// Loads PDFs through PDFKit, a page at a time or as one document.
///
/// Extracts the text layer only — a scanned PDF with no embedded text yields empty pages, which
/// are skipped. Recognising those needs OCR, which is a later phase.
public struct RTSRAGPDFLoader: RTSRAGDocumentLoader {
    static let supportedExtensions: Set<String> = ["pdf"]

    /// How a PDF becomes documents.
    public enum Granularity: Sendable {
        /// One document per page. The default: pages are a natural retrieval unit and keep a hit
        /// traceable to a page number.
        case page
        /// One document for the whole file, pages joined by a blank line. Suits short PDFs where
        /// splitting would strand context.
        case document
    }

    private let path: URL
    private let granularity: Granularity

    public init(
        path: URL,
        granularity: Granularity = .page
    ) {
        self.path = path
        self.granularity = granularity
    }

    public func stream() throws -> RTSRAGDocumentStream {
        let resolved = try RTSRAGFileEnumeration.resolveSources(
            at: path,
            extensions: RTSRAGPDFLoader.supportedExtensions
        )
        let granularity = self.granularity
        return RTSRAGDocumentStream(sources: resolved) { url in
            try RTSRAGPDFLoader.makeDocuments(at: url, granularity: granularity)
        }
    }

    private static func makeDocuments(
        at url: URL,
        granularity: Granularity
    ) throws -> [RTSRAGDocument] {
        guard let pdf = PDFDocument(url: url) else {
            throw RTSRAGError.loadFailed(source: url.path, reason: "could not open PDF")
        }
        var pages: [(number: Int, text: String)] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else {
                continue
            }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Empty pages are skipped rather than stored: an image-only page has no text layer, and
            // embedding an empty string wastes a request and pollutes results.
            guard !text.isEmpty else {
                continue
            }
            pages.append((number: index + 1, text: text))
        }
        guard !pages.isEmpty else {
            return []
        }

        switch granularity {
        case .page:
            return pages.map { page in
                RTSRAGDocument(
                    content: page.text,
                    type: .pdf,
                    // `#page-N`, **not** the bare path. Python reuses the file path as the source
                    // for every page, so all of a PDF's pages derive the same UUID5 and collide on
                    // one document id — under the store's replace-by-id, each page would evict the
                    // last. The page number has to be part of the identity.
                    source: "\(url.path)#page-\(page.number)",
                    metadata: [
                        "page": .integer(page.number),
                        "page_count": .integer(pdf.pageCount),
                    ]
                )
            }
        case .document:
            return [
                RTSRAGDocument(
                    content: pages.map { $0.text }.joined(separator: "\n\n"),
                    type: .pdf,
                    source: url.path,
                    metadata: [
                        "page_count": .integer(pdf.pageCount),
                        "pages_with_text": .integer(pages.count),
                    ]
                )
            ]
        }
    }
}
