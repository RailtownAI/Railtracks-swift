//
//  RTSUILogger.swift
//  RailtracksSwiftUI
//

import Foundation
import Logging

/// Mirrors `RailtracksSwift`'s own `log`, which is internal to that module and so unavailable here.
///
/// Deliberately uses the same label, so UI diagnostics land in the same stream as the library's and a
/// developer only has one thing to filter on.
internal let log = Logger(label: "railtracks.swift.log")
