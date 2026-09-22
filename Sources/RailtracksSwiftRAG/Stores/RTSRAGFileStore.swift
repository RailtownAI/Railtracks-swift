//
//  RTSRAGFileStore.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-18.
//

import Foundation

/// A durable store backed by an append-only JSONL log, with the whole index held in memory.
///
/// Reads never touch disk. Writes append one line and update the index, so a write costs one
/// document's worth of I/O rather than the corpus's.
///
/// ## One line per document, not per entry
///
/// ``RTSRAGVectorStore/replaceDocument(id:with:)`` is documented as **one operation**, precisely so
/// a concurrent ingest cannot observe a half-replaced document. A replacement spread across N
/// appended lines would be exactly the interleaving that rule exists to prevent — so a line holds a
/// document's entire set of entries, and line-level atomicity *is* document-level atomicity.
///
/// It also buys crash tolerance: a torn final line loses one document, which the staleness check
/// then re-ingests, rather than corrupting the store.
///
/// ```
/// {"documentID":"…","entries":[ … all chunks … ]}   ← later lines supersede earlier ones
/// {"documentID":"…","entries":[]}                   ← a tombstone
/// ```
///
/// ## Why not a file per document
///
/// That is atomically *stronger* — write a temp file and `rename`, which the filesystem guarantees,
/// so a torn write is impossible rather than merely detectable, and compaction is never needed.
/// What rules it out is this library's own granularity: CSV and JSON loaders emit one document per
/// **record**, so a 10,000-row CSV becomes 10,000 documents and therefore 10,000 files — each
/// taking a 4KB block for perhaps 200 bytes, with a directory walk on every open. The log reads the
/// same corpus in one sequential pass.
///
/// The accepted cost is a possible torn final line, plus periodic compaction.
public actor RTSRAGFileStore: RTSRAGVectorStore {

    /// One line of the log: a document and everything stored for it.
    private struct Record: Codable {
        let documentID: RTSRAGDocumentID
        let entries: [RTSRAGStoreEntry]
    }

    private let fileURL: URL
    private var index = RTSRAGStoreIndex()
    /// Lines in the file, live or superseded. The compaction trigger.
    private var lineCount = 0

    /// Opens the store at `directory`, replaying any existing log.
    ///
    /// - Parameter directory: created if absent. Supplied by the caller rather than derived from
    ///   `RailtracksSwift.outputDirectory`, which lives in the module this one deliberately does
    ///   not depend on.
    public init(directory: URL) throws {
        let fileURL = directory.appendingPathComponent("entries.jsonl")
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Replay is a static returning its result rather than an isolated method: an actor's
        // initialiser cannot call one, and the state it builds belongs to the actor from the first
        // moment anyway.
        let replayed = try RTSRAGFileStore.replay(at: fileURL)
        self.lineCount = replayed.lineCount
        try self.index.reset(to: replayed.documents)
    }

    // MARK: - RTSRAGVectorStore

    public func replaceDocument(
        id: RTSRAGDocumentID,
        with entries: [RTSRAGStoreEntry]
    ) async throws {
        try apply(entries, to: id)
    }

    public func deleteDocument(id: RTSRAGDocumentID) async throws {
        // A tombstone rather than rewriting the file: the delete has to survive a replay, and an
        // empty entry list is how a replay learns the document is gone. The index reads an empty
        // replacement as a removal, so a delete is the same operation with nothing in it.
        try apply([], to: id)
    }

    public func search(_ query: RTSRAGStoreQuery) async throws -> [RTSRAGRetrievedEntry] {
        try index.validateQuery(query)
        return index.search(query)
    }

    public func find(
        matching filters: RTSRAGMetadata,
        limit: Int
    ) async throws -> [RTSRAGStoreEntry] {
        index.find(matching: filters, limit: limit)
    }

    public func count(matching filters: RTSRAGMetadata) async throws -> Int {
        index.count(matching: filters)
    }

    // MARK: - Log

    /// Writes `entries` to the index and the log together, or to neither.
    ///
    /// Two guards, in order, because they fail at different moments:
    ///
    /// - **The index validates first**, so a document from a foreign embedder neither enters memory
    ///   nor reaches the log, and the previous version survives a rejected replacement.
    /// - **A failed append is rolled back.** Reads answer from the index, so leaving the new
    ///   document there after the log refused it would make ``RTSRAGRetrievalRuntime`` report the
    ///   document as uncommitted and then *skip* it on every later run in this process — its
    ///   staleness check would find the write that never happened. Worse, compaction serialises the
    ///   index, so a later compaction would quietly persist it.
    ///
    ///   The rollback goes through ``RTSRAGStoreIndex/DocumentSnapshot`` rather than re-replacing
    ///   the document, because a write changes more than the document: the *first* one also latches
    ///   the store's model and dimension, and undoing only the document left an empty store pinned
    ///   to a model whose single document was never written.
    private func apply(_ entries: [RTSRAGStoreEntry], to id: RTSRAGDocumentID) throws {
        let snapshot = index.snapshot(of: id)
        try index.replace(documentID: id, with: entries)
        do {
            try append(Record(documentID: id, entries: entries))
        } catch {
            index.restore(snapshot, for: id)
            throw error
        }
        try compactIfNeeded()
    }

    /// Reads the log back into a document map, last write winning.
    private static func replay(
        at fileURL: URL
    ) throws -> (documents: [RTSRAGDocumentID: [RTSRAGStoreEntry]], lineCount: Int) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([:], 0)
        }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var documents: [RTSRAGDocumentID: [RTSRAGStoreEntry]] = [:]
        var lines = 0
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)) else {
                // Only the final line can be torn — a crash mid-append. Anything earlier means a
                // corrupt file, but the response is the same either way: skip it and carry on, so
                // one bad document cannot deny the rest of the corpus. The staleness check will
                // re-ingest whatever went missing.
                ragLog.warning("📚 skipping an unreadable line in \(fileURL.lastPathComponent)")
                continue
            }
            lines += 1
            if record.entries.isEmpty {
                documents.removeValue(forKey: record.documentID)
            } else {
                documents[record.documentID] = record.entries
            }
        }
        return (documents, lines)
    }

    /// Appends one line, or throws having written nothing.
    ///
    /// **Never falls back to a whole-file write.** An earlier version opened the handle with `try?`
    /// and, when that failed, wrote the single line with `.atomic` — intending "the file does not
    /// exist yet". `try?` does not ask that question: it fires on *any* open failure, so a
    /// permissions change or an exhausted descriptor table replaced the entire log with one line.
    /// Creating the file explicitly asks what was meant, and leaves the open failure as a real error.
    private func append(_ record: Record) throws {
        var line = try JSONEncoder().encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        lineCount += 1
    }

    /// Rewrites the log with only live documents once superseded lines outnumber them.
    ///
    /// Twice the live count is the trigger: an edit-heavy corpus would otherwise grow without
    /// bound, since every replacement appends rather than editing in place.
    private func compactIfNeeded() throws {
        let live = index.documents.count
        guard lineCount > max(8, live * 2) else {
            return
        }
        let encoder = JSONEncoder()
        var data = Data()
        for (id, entries) in index.documents {
            data.append(try encoder.encode(Record(documentID: id, entries: entries)))
            data.append(0x0A)
        }
        // Atomic, so a crash during compaction leaves the old log intact rather than a partial
        // rewrite — the one place this store gets filesystem-level atomicity, and it is worth
        // having here because compaction touches every document at once.
        try data.write(to: fileURL, options: .atomic)
        lineCount = live
    }
}
