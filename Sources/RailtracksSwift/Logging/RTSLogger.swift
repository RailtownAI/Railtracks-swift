//
//  RTSLogger.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-28.
//

import Foundation
import Logging

/// Development Loggers for RailtracksSwift Library
///
/// Should follow Swift Library [log guide line]:  https://www.swift.org/documentation/server/guides/libraries/log-levels.html
internal enum RTSLoggers {
    static let rtsLogLabel = "railtracks.swift.log"
    static let rtsLog = RTSLog(label: RTSLoggers.rtsLogLabel)
}

/// The library's logger: swift-log's `Logger` behind a type of the library's own.
///
/// The package enables `MemberImportVisibility`, so calling a `Logger` method directly would need
/// `import Logging` in every file that logs. These methods are this module's own, so a file can
/// call `log.debug(...)` with no import; only this file imports `Logging`.
///
/// It changes nothing an app sees: the `Logger` inside is created the same way, so it uses the
/// handler and level the app bootstrapped. Each method keeps the message an `@autoclosure`, so it
/// is only built when its level is enabled, and passes the caller's file, function and line on, so
/// a log line points at the code that logged it and its `source` is still this module.
internal struct RTSLog: Sendable {
    private let logger: Logger

    init(label: String) {
        logger = Logger(label: label)
    }

    func trace(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        logger.trace("\(message())", file: file, function: function, line: line)
    }

    func debug(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        logger.debug("\(message())", file: file, function: function, line: line)
    }

    func info(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        logger.info("\(message())", file: file, function: function, line: line)
    }

    func warning(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        logger.warning("\(message())", file: file, function: function, line: line)
    }

    func error(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        logger.error("\(message())", file: file, function: function, line: line)
    }
}
