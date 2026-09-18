//
//  RTSRAGLogging.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation
import Logging

/// Development logger for the retrieval module.
///
/// Its own label rather than reusing `RTSLoggers`, so nothing in this module imports
/// RailtracksSwift for logging alone — one of the couplings the port deliberately avoids.
///
/// Follows the Swift library
/// [log level guidance](https://www.swift.org/documentation/server/guides/libraries/log-levels.html)
/// and the repository convention of an emoji prefix per subsystem: 📚 here, alongside 🎁 for the
/// flow-graph collector, 📮 for the event writer, 🧪 for evaluation.
internal enum RTSRAGLoggers {
    static let ragLogLabel = "railtracks.swift.rag.log"
    static let ragLog = Logger(label: RTSRAGLoggers.ragLogLabel)
}

/// Module-wide shorthand, mirroring RailtracksSwift's global `log`.
internal let ragLog = RTSRAGLoggers.ragLog
