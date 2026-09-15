//
//  RTSRAGLoaderTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-15.
//

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import RailtracksSwiftRAG

/// Phase 2 of the RAG port: loaders.
///
/// Fixtures are generated into a unique temp directory per test and removed afterwards, mirroring
/// Python's `conftest.py` — which has no binary assets either, so the cases port directly.
@Suite("RailtracksSwiftRAG loaders")
struct RTSRAGLoaderTests {

    // MARK: - Helpers

    /// A unique directory for one test, plus the cleanup its caller defers.
    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rts-rag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func write(
        _ contents: String,
        to directory: URL,
        named name: String
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Drains a loader, separating what loaded from what failed.
    private static func drain(
        _ loader: some RTSRAGDocumentLoader
    ) async throws -> (documents: [RTSRAGDocument], failures: [RTSRAGError]) {
        var documents: [RTSRAGDocument] = []
        var failures: [RTSRAGError] = []
        for await element in try loader.stream() {
            switch element {
            case .success(let document):
                documents.append(document)
            case .failure(let error):
                failures.append(error)
            }
        }
        return (documents, failures)
    }

    // MARK: - Text

    @Test("a directory loads in sorted order with per-file types")
    func textDirectory() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try Self.write("alpha", to: directory, named: "a.txt")
        _ = try Self.write("# beta", to: directory, named: "b.md")
        _ = try Self.write("gamma", to: directory, named: "c.txt")

        let (documents, failures) = try await Self.drain(RTSRAGTextLoader(path: directory))

        // Sorted explicitly, because neither FileManager nor rglob guarantees an order and the
        // ingest order decides which documents reach the store first.
        #expect(documents.map { $0.content } == ["alpha", "# beta", "gamma"])
        #expect(documents.map { $0.type } == [.text, .markdown, .text])
        #expect(failures.isEmpty)
    }

    @Test("a source yields a stable id, so re-ingesting an edit replaces it")
    func textSourceIdentity() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try Self.write("first draft", to: directory, named: "policy.md")
        let before = try await Self.drain(RTSRAGTextLoader(path: url)).documents

        try "second draft".write(to: url, atomically: true, encoding: .utf8)
        let after = try await Self.drain(RTSRAGTextLoader(path: url)).documents

        // Same source, different content — the id must not move, or the update would add a
        // second copy instead of replacing the first.
        #expect(before[0].id == after[0].id)
        #expect(before[0].content != after[0].content)
    }

    // MARK: - CSV

    @Test("a CSV row becomes labelled column-value pairs, one document per row")
    func csvRows() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try Self.write(
            "name,age,city\nAlice,30,NYC\nBob,25,LA\n",
            to: directory,
            named: "people.csv"
        )

        let (documents, _) = try await Self.drain(RTSRAGCSVLoader(path: url))

        #expect(documents.count == 2)
        // Column names are part of what gets embedded — "Alice,30,NYC" alone would not tell a
        // similarity search which field is which.
        #expect(documents[0].content == "name: Alice\nage: 30\ncity: NYC")
        #expect(documents.map { $0.source } == ["\(url.path)#0", "\(url.path)#1"])
    }

    @Test("an id column makes row identity survive reordering")
    func csvIDColumn() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let original = try Self.write(
            "id,name\n7,Alice\n9,Bob\n",
            to: directory,
            named: "keyed.csv"
        )
        let before = try await Self.drain(
            RTSRAGCSVLoader(path: original, contentColumns: ["name"], idColumn: "id")
        ).documents

        // Swap the rows. With positional ids every document below an insertion would be
        // re-identified; keyed on a column, identity holds.
        try "id,name\n9,Bob\n7,Alice\n".write(to: original, atomically: true, encoding: .utf8)
        let after = try await Self.drain(
            RTSRAGCSVLoader(path: original, contentColumns: ["name"], idColumn: "id")
        ).documents

        #expect(Set(before.map { $0.id }) == Set(after.map { $0.id }))
        #expect(before[0].content == "name: Alice")
    }

    @Test("non-content columns become filterable metadata")
    func csvMetadata() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try Self.write(
            "name,age,city\nAlice,30,NYC\n",
            to: directory,
            named: "people.csv"
        )

        let (documents, _) = try await Self.drain(
            RTSRAGCSVLoader(path: url, contentColumns: ["name"], ignoreColumns: ["city"])
        )

        #expect(documents[0].content == "name: Alice")
        #expect(documents[0].metadata["age"] == .string("30"))
        #expect(documents[0].metadata["city"] == nil)     // ignored, not merely uncontented
        #expect(documents[0].metadata["row_index"] == .integer(0))
    }

    @Test("quoted CSV fields survive embedded commas and newlines")
    func csvQuoting() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        // Splitting on commas would corrupt this, which is most real-world CSV.
        let url = try Self.write(
            "name,note\nAlice,\"Said \"\"hi\"\", then left\"\n",
            to: directory,
            named: "quoted.csv"
        )

        let (documents, _) = try await Self.drain(RTSRAGCSVLoader(path: url))

        #expect(documents.count == 1)
        #expect(documents[0].content.contains("Said \"hi\", then left"))
    }

    @Test("a UTF-8 byte-order mark does not leak into the header or content")
    func csvByteOrderMark() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("bom.csv")
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append("name,age\nAlice,30\n".data(using: .utf8)!)
        try bytes.write(to: url)

        // Foundation strips the BOM for us, so there is no stripping code to test — this pins a
        // behaviour we depend on. Without it the first header cell would be "\u{FEFF}name", and a
        // configured content column would fail to match, reported as an unknown column. BOMs are
        // common in Excel-exported CSV, so this is the likely first real-world encounter.
        let (documents, _) = try await Self.drain(
            RTSRAGCSVLoader(path: url, contentColumns: ["name"])
        )

        #expect(documents.count == 1)
        #expect(documents[0].content == "name: Alice")
    }

    // MARK: - JSON

    @Test("a JSON array yields one document per object, JSONL one per line")
    func jsonShapes() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try Self.write(#"[{"a":1},{"a":2}]"#, to: directory, named: "array.json")
        // A blank line in the middle: it must be skipped, and `index` must count objects rather
        // than lines, or every identity below it would shift.
        _ = try Self.write("{\"a\":3}\n\n{\"a\":4}\n", to: directory, named: "lines.jsonl")

        let (documents, failures) = try await Self.drain(RTSRAGJSONLoader(path: directory))

        #expect(failures.isEmpty)
        #expect(documents.count == 4)
        #expect(documents.filter { $0.type == .json }.count == 2)
        #expect(documents.filter { $0.type == .jsonLines }.count == 2)
        let lineDocuments = documents.filter { $0.type == .jsonLines }
        #expect(lineDocuments.map { $0.metadata["index"] } == [.integer(0), .integer(1)])
    }

    @Test("explicit content keys shape content and route the rest to metadata")
    func jsonContentKeys() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try Self.write(
            #"{"title":"Refunds","body":"30 days","region":"TX"}"#,
            to: directory,
            named: "doc.json"
        )

        let (documents, _) = try await Self.drain(
            RTSRAGJSONLoader(path: url, contentKeys: ["title", "body"], idKey: "title")
        )

        #expect(documents[0].content == "title: Refunds\nbody: 30 days")
        #expect(documents[0].metadata["region"] == .string("TX"))
        #expect(documents[0].source == "\(url.path)#Refunds")
    }

    // MARK: - PDF

    @Test("each PDF page gets a distinct source, so pages do not collide on one id")
    func pdfPageIdentity() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("doc.pdf")
        try #require(Self.writePDF(pages: ["First page text", "Second page text"], to: url))

        let (documents, failures) = try await Self.drain(RTSRAGPDFLoader(path: url))

        #expect(failures.isEmpty)
        #expect(documents.count == 2)
        // The regression test for Python's bug: it reuses the file path as the source for every
        // page, so all pages derive the same UUID5 and evict one another under replace-by-id.
        #expect(Set(documents.map { $0.id }).count == 2)
        #expect(documents[0].source == "\(url.path)#page-1")
        #expect(documents[0].metadata["page"] == .integer(1))
    }

    @Test("document granularity joins pages into one document")
    func pdfWholeDocument() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("doc.pdf")
        try #require(Self.writePDF(pages: ["Alpha", "Beta"], to: url))

        let (documents, _) = try await Self.drain(
            RTSRAGPDFLoader(path: url, granularity: .document)
        )

        #expect(documents.count == 1)
        #expect(documents[0].content.contains("Alpha"))
        #expect(documents[0].content.contains("Beta"))
        #expect(documents[0].source == url.path)
    }

    /// Builds a PDF with a real text layer, so the suite needs no binary fixture.
    ///
    /// Drawn through a Core Graphics PDF context rather than `PDFPage(image:)` — an image-backed
    /// page carries no text layer, so `PDFPage.string` would be nil and the loader would correctly
    /// find nothing to extract.
    private static func writePDF(pages: [String], to url: URL) -> Bool {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            return false
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return false
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return (data as Data).withUnsafeBytes { _ in
            (try? (data as Data).write(to: url)) != nil
        }
    }

    // MARK: - Errors

    @Test("a missing path throws rather than yielding a failure element")
    func missingPathThrows() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rts-rag-absent-\(UUID().uuidString)")

        // A precondition failure: the loader was pointed at the wrong thing, so every element
        // would be wrong. It surfaces at the call site rather than as the first element.
        #expect(throws: RTSRAGError.self) {
            _ = try RTSRAGTextLoader(path: missing).stream()
        }
    }

    @Test("one unreadable file does not abandon the rest of the directory")
    func perFileFailureContinues() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try Self.write("alpha", to: directory, named: "a.txt")
        // Invalid UTF-8 — readable as bytes, undecodable as text.
        try Data([0xFF, 0xFE, 0xFD]).write(to: directory.appendingPathComponent("b.txt"))
        _ = try Self.write("gamma", to: directory, named: "c.txt")

        let (documents, failures) = try await Self.drain(RTSRAGTextLoader(path: directory))

        // The departure from Python, where one bad file aborts the whole ingestion run.
        #expect(documents.map { $0.content } == ["alpha", "gamma"])
        #expect(failures.count == 1)
    }

    // MARK: - Sanitizing

    @Test("a sanitizer transforms content and can drop documents")
    func sanitizing() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try Self.write("keep me", to: directory, named: "a.txt")
        _ = try Self.write("DROP", to: directory, named: "b.txt")
        _ = try Self.write("keep me too", to: directory, named: "c.txt")

        let loader = RTSRAGSanitizingLoader(
            wrapping: RTSRAGTextLoader(path: directory),
            sanitizer: UppercasingSanitizer()
        )
        let (documents, failures) = try await Self.drain(loader)

        // Dropping is the capability Python cannot express — its sanitizer must return a document.
        #expect(documents.map { $0.content } == ["KEEP ME", "KEEP ME TOO"])
        #expect(failures.isEmpty)
    }

    @Test("a throwing sanitizer fails its source rather than being swallowed")
    func sanitizerErrorsPropagate() async throws {
        let directory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try Self.write("anything", to: directory, named: "a.txt")

        let loader = RTSRAGSanitizingLoader(
            wrapping: RTSRAGTextLoader(path: directory),
            sanitizer: ThrowingSanitizer()
        )
        // A misconfigured sanitizer is wrong for every document, not just this one — so it is not
        // a per-item failure. It surfaces as a `.failure` carrying the underlying error rather
        // than being silently swallowed.
        let (documents, failures) = try await Self.drain(loader)
        #expect(documents.isEmpty)
        #expect(failures.count == 1)
    }
}

// MARK: - Test doubles

private struct UppercasingSanitizer: RTSRAGSanitizer {
    func sanitize(_ document: RTSRAGDocument) async throws -> RTSRAGDocument? {
        guard document.content != "DROP" else {
            return nil
        }
        return RTSRAGDocument(
            content: document.content.uppercased(),
            type: document.type,
            source: document.source,
            id: document.id,
            metadata: document.metadata
        )
    }
}

private struct SanitizerFailure: Error {
}

private struct ThrowingSanitizer: RTSRAGSanitizer {
    func sanitize(_ document: RTSRAGDocument) async throws -> RTSRAGDocument? {
        throw SanitizerFailure()
    }
}
