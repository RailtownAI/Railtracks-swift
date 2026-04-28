//
//  RTSLogger.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-28.
//

import Foundation
import Logging

/// Loggers for RailtracksSwift Library
///
/// Should follow Swift Library [log guide line]:  https://www.swift.org/documentation/server/guides/libraries/log-levels.html
internal enum RTSLoggers {
    static let rtsLog = Logger(label: "railtracks.swift.log")
}
