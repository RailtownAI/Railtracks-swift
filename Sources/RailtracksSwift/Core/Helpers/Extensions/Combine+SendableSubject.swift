//
//  Combine+SendableSubject.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-12.
//

import Foundation
import Combine

/// PassthroughSubject that buffers all sent values and replays them to new subscribers.
/// Guarantees late subscribers receive all previously sent values regardless of subscription timing.
internal final class BufferedPassthroughSubject<Output>: @unchecked Sendable {
    private let subject = PassthroughSubject<Output, Never>()
    private var buffer: [Output] = []
    private let lock = NSLock()

    func send(_ value: Output) {
        lock.withLock { buffer.append(value) }
        subject.send(value)
    }

    var replayPublisher: AnyPublisher<Output, Never> {
        let buffered = lock.withLock { buffer }
        return Publishers.Sequence(sequence: buffered)
            .append(subject)
            .eraseToAnyPublisher()
    }
}
