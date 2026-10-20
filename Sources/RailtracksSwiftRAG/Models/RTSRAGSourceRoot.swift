//
//  RTSRAGSourceRoot.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-30.
//

import Foundation

/// A file or folder, and the rule for which stored document sources lie under it.
///
/// Used twice: as the extent of an orphan sweep — what one ingest run covers — and as the target
/// of `removeSource(at:)`. See `docs/rag-orphan-sweep.md`.
///
/// ## The rule
///
/// A source is under a root when it **equals** the root's path, or **starts with** the path
/// followed by `#` or `/`:
///
/// | Source | Meaning |
/// |---|---|
/// | `<path>` | the whole file |
/// | `<path>#page-3`, `<path>#row-7`, `<path>#<id>` | part of that file: a page, row or object |
/// | `<path>/<more>` | something inside that folder |
///
/// One rule serves a file root, a folder root, and a path that no longer exists — which is exactly
/// when `removeSource(at:)` is called, so asking the file system which kind it was is not an
/// option. The separators are what stop `/a/b` from claiming `/a/bc`.
///
/// ## One location, several spellings
///
/// On Apple platforms `/var`, `/tmp` and `/etc` are links into `/private`, and directory
/// enumeration reports children by the **resolved** spelling: a loader pointed at
/// `/var/folders/…/docs` stores `/private/var/folders/…/docs/a.txt`. Matching only the spelling
/// the root was given would find none of a folder's documents — every sweep a silent no-op, and
/// `removeSource(at:)` missing what it was asked to remove. So a root matches under each of
/// ``spellings``: as given, canonical (when the path exists), and its `/private` counterpart, which
/// is what still works once the path is gone.
public struct RTSRAGSourceRoot: Sendable, Hashable {
    /// The root as given, spelled as loaders spell sources: `URL.path`, with no trailing slash.
    public let path: String
    /// Every spelling of the same location a stored source may use, ``path`` first.
    public let spellings: [String]

    public init(_ url: URL) {
        var alternates: [String] = []
        if let canonical = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            alternates.append(canonical)
        }
        self.init(path: url.path, alternates: alternates)
    }

    public init(path: String) {
        self.init(path: path, alternates: [])
    }

    private init(path: String, alternates: [String]) {
        let primary = RTSRAGSourceRoot.trimmed(path)
        var spellings = [primary]
        let counterpart = RTSRAGSourceRoot.privateCounterpart(of: primary)
        let candidates = alternates.map(RTSRAGSourceRoot.trimmed) + [counterpart].compactMap { $0 }
        for candidate in candidates where !spellings.contains(candidate) {
            spellings.append(candidate)
        }
        self.path = primary
        self.spellings = spellings
    }

    /// Whether `source` is this root, a part of it, or inside it — under any of its spellings.
    public func contains(source: String) -> Bool {
        spellings.contains { spelling in
            source == spelling
                || source.hasPrefix(spelling + "#")
                || source.hasPrefix(spelling + "/")
        }
    }

    // MARK: - Spelling

    /// Without a trailing slash, which would make the `/` separator rule look for `//`. A lone `/`
    /// is left alone rather than emptied.
    private static func trimmed(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// The same location with `/private` added or removed, for the top-level links into it.
    private static func privateCounterpart(of path: String) -> String? {
        let linked = ["/var", "/tmp", "/etc"]
        func isLinked(_ candidate: String) -> Bool {
            linked.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
        }
        if path.hasPrefix("/private/") {
            let unprefixed = String(path.dropFirst("/private".count))
            return isLinked(unprefixed) ? unprefixed : nil
        }
        return isLinked(path) ? "/private" + path : nil
    }
}
