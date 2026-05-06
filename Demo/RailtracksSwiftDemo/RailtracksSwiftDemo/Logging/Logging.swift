//
//  Logging+Bootstrap.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-28.
//

import Logging

/// Setup for Logging usage
enum Log {
    nonisolated private static let logger = Logger(label: "railtracks-swift-demo")

    /// Bootstrap logging.  This should happen before App initializes any views.
    private static let _bootstrap: Void = {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .trace
            return handler
        }
    }()

    static func setup() {
        _ = _bootstrap
    }

    nonisolated static func debug(_ message: @autoclosure () -> Logger.Message) {
        logger.debug(message())
    }

    nonisolated static func info(_ message: @autoclosure () -> Logger.Message) {
        logger.info(message())
    }

    nonisolated static func error(_ message: @autoclosure () -> Logger.Message) {
        logger.error(message())
    }
}
