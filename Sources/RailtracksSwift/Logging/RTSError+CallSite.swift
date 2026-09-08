//
//  RTSError+CallSite.swift
//  RailtracksSwift
//

import RailtownLogger

extension RTSError {
    /// The recorded raise site in RailtownLogger's shape, so an uploaded error
    /// report points at the code that threw rather than the flow that reported it.
    var railtownCallSite: CallSite {
        CallSite(file: context.file, function: context.function, line: Int(clamping: context.line))
    }
}
