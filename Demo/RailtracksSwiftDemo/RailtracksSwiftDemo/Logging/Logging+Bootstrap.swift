//
//  Logging+Bootstrap.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-28.
//

import Logging

/// Bootstrap logging.  This should happen before App initializes any views.
/// Trigger it by `_ = _loggingBootstrap`
let _loggingBootstrap: Void = {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel = .trace
        return handler
    }
}()
