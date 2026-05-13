//
//  Combine+SendableSubject.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-12.
//

import Foundation
import Combine

/// Wrapper around passthrough subject so it can be use in sendable context
internal final class SendablePassthroughSubject<Output>: @unchecked Sendable {
    let subject = PassthroughSubject<Output, Never>()
    func send(_ value: Output) { subject.send(value) }
}
