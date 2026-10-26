//
//  RTSRAGAssetRequestTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-10-21.
//

import Foundation
import NaturalLanguage
import Synchronization
import Testing
@testable import RailtracksSwiftRAG

/// The race behind `RTSRAGAppleEmbedding.prepare(timeout:)`, driven with fake requests.
///
/// Fakes rather than Apple's model because the test Mac already has the assets, so `prepare`
/// returns before reaching any of this. Every test uses its own key: the registry is process-wide,
/// and this suite runs in parallel.
@Suite("RailtracksSwiftRAG asset request")
struct RTSRAGAssetRequestTests {

    /// A fake request that answers only when released, and counts how often it was started.
    private final class FakeRequest: Sendable {
        let starts = Mutex(0)
        private let release: AsyncStream<NLContextualEmbedding.AssetsResult>.Continuation
        private let answers: AsyncStream<NLContextualEmbedding.AssetsResult>

        init() {
            let (answers, release) = AsyncStream<NLContextualEmbedding.AssetsResult>.makeStream()
            self.answers = answers
            self.release = release
        }

        var startCount: Int {
            starts.withLock { $0 }
        }

        func start() async throws -> NLContextualEmbedding.AssetsResult {
            starts.withLock { $0 += 1 }
            for await answer in answers {
                return answer
            }
            return .error
        }

        func answer(_ result: NLContextualEmbedding.AssetsResult) {
            release.yield(result)
        }
    }

    /// A fake `hasAvailableAssets`: false until `arrive()`, counting every check.
    private final class FakeAssets: Sendable {
        private let arrived = Mutex(false)
        private let checks = Mutex(0)

        var checkCount: Int {
            checks.withLock { $0 }
        }

        func check() -> Bool {
            checks.withLock { $0 += 1 }
            return arrived.withLock { $0 }
        }

        func arrive() {
            arrived.withLock { $0 = true }
        }
    }

    private static let checkInterval: Duration = .milliseconds(20)

    private static func shared(
        _ fake: FakeRequest,
        key: String,
        assets: FakeAssets,
        staleAfter: Duration = RTSRAGAssetRequest.defaultStaleAfter
    ) -> RTSRAGAssetRequest {
        RTSRAGAssetRequest.shared(
            key: key,
            start: {
                try await fake.start()
            },
            assetsArrived: {
                assets.check()
            },
            checkInterval: checkInterval,
            staleAfter: staleAfter
        )
    }

    private static func uniqueKey() -> String {
        "test-asset-\(UUID().uuidString)"
    }

    private static func shared(_ fake: FakeRequest, key: String) -> RTSRAGAssetRequest {
        RTSRAGAssetRequest.shared(key: key) {
            try await fake.start()
        }
    }

    // MARK: - Timeout

    @Test("a request that never answers times out promptly")
    func neverAnsweringRequestTimesOut() async throws {
        let fake = FakeRequest()
        let request = Self.shared(fake, key: Self.uniqueKey())
        let clock = ContinuousClock()

        let started = clock.now
        let outcome = try await request.wait(timeout: .milliseconds(100))

        // The whole point: the caller gets control back, though the request never answered.
        #expect(outcome == nil)
        #expect(clock.now - started < .seconds(2))
    }

    @Test("a fast request returns its result, with a timeout or without one")
    func fastRequestReturnsItsResult() async throws {
        let bounded = FakeRequest()
        let boundedRequest = Self.shared(bounded, key: Self.uniqueKey())
        bounded.answer(.available)
        let unbounded = FakeRequest()
        let unboundedRequest = Self.shared(unbounded, key: Self.uniqueKey())
        unbounded.answer(.notAvailable)

        #expect(try await boundedRequest.wait(timeout: .seconds(30)) == .available)
        #expect(try await unboundedRequest.wait(timeout: nil) == .notAvailable)
    }

    @Test("a zero timeout returns at once, with the request started")
    func zeroTimeoutStartsTheRequestWithoutWaiting() async throws {
        let fake = FakeRequest()
        let request = Self.shared(fake, key: Self.uniqueKey())

        let outcome = try await request.wait(timeout: .zero)

        // Zero means what it says: no wait, but the download it asked for is under way.
        #expect(outcome == nil)
        try await waitUntil { fake.startCount == 1 }
        fake.answer(.available)
        #expect(try await request.wait(timeout: nil) == .available)
    }

    // MARK: - Cancellation

    @Test("a cancelled caller stops waiting, and the request keeps running")
    func cancelledCallerLeavesTheRequestRunning() async throws {
        let fake = FakeRequest()
        let request = Self.shared(fake, key: Self.uniqueKey())

        let waiting = Task {
            try await request.wait(timeout: nil)
        }
        try await waitUntil { fake.startCount == 1 }
        waiting.cancel()

        // Without the race, this await would never return: Apple's request ignores cancellation.
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        fake.answer(.available)
        #expect(try await request.wait(timeout: nil) == .available)
    }

    @Test("a caller cancelled before it waits is not left waiting")
    func alreadyCancelledCallerThrowsAtOnce() async throws {
        let fake = FakeRequest()
        let request = Self.shared(fake, key: Self.uniqueKey())

        let waiting = Task {
            // Cancelled before reaching `wait`: the handler runs before there is anything to
            // resume.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await request.wait(timeout: nil)
        }

        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
    }

    // MARK: - Sharing

    @Test("concurrent callers share one request")
    func concurrentCallersShareOneRequest() async throws {
        let fake = FakeRequest()
        let key = Self.uniqueKey()
        let first = Self.shared(fake, key: key)
        let second = Self.shared(fake, key: key)

        async let firstOutcome = first.wait(timeout: nil)
        async let secondOutcome = second.wait(timeout: nil)
        try await waitUntil { fake.startCount == 1 }
        fake.answer(.available)

        #expect(try await firstOutcome == .available)
        #expect(try await secondOutcome == .available)
        #expect(first === second)
        #expect(fake.startCount == 1)
    }

    @Test("one caller timing out leaves another still waiting on the same request")
    func timeoutIsPerCaller() async throws {
        let fake = FakeRequest()
        let key = Self.uniqueKey()
        let patientFinished = Mutex(false)

        let patient = Task {
            let outcome = try await Self.shared(fake, key: key).wait(timeout: nil)
            patientFinished.withLock { $0 = true }
            return outcome
        }
        try await waitUntil { fake.startCount == 1 }
        let impatient = try await Self.shared(fake, key: key).wait(timeout: .milliseconds(50))

        // Two ingest flows on one download: the first giving up removes only its own wait, so the
        // second is still waiting, and gets the answer when it comes.
        #expect(impatient == nil)
        #expect(patientFinished.withLock { $0 } == false)
        fake.answer(.available)
        #expect(try await patient.value == .available)
        #expect(fake.startCount == 1)
    }

    @Test("a caller arriving after a timeout joins the same request")
    func callerAfterTimeoutJoinsTheRequest() async throws {
        let fake = FakeRequest()
        let key = Self.uniqueKey()

        let timedOut = try await Self.shared(fake, key: key).wait(timeout: .milliseconds(50))
        let rejoined = Self.shared(fake, key: key)
        async let outcome = rejoined.wait(timeout: nil)
        fake.answer(.available)

        // "Let me wait it out": the second wait gets the first request's answer, not a new request.
        #expect(timedOut == nil)
        #expect(try await outcome == .available)
        #expect(fake.startCount == 1)
    }

    @Test("a finished request is forgotten, so the next caller asks again")
    func finishedRequestIsReplaced() async throws {
        let first = FakeRequest()
        let key = Self.uniqueKey()
        let firstRequest = Self.shared(first, key: key)
        first.answer(.notAvailable)
        // Unregistered before any waiter is resumed, so by the time this returns it is gone.
        #expect(try await firstRequest.wait(timeout: nil) == .notAvailable)

        // After `.notAvailable`, asking again is the only way to learn whether that changed.
        let second = FakeRequest()
        let secondRequest = Self.shared(second, key: key)
        second.answer(.available)

        #expect(secondRequest !== firstRequest)
        #expect(try await secondRequest.wait(timeout: nil) == .available)
        #expect(first.startCount == 1)
    }

    // MARK: - Asset check

    @Test("the assets arriving resolve the waiters, though the request never answers")
    func arrivingAssetsResolveWithoutAnAnswer() async throws {
        let fake = FakeRequest()
        let assets = FakeAssets()
        let request = Self.shared(fake, key: Self.uniqueKey(), assets: assets)

        async let outcome = request.wait(timeout: .seconds(30))
        try await waitUntil { assets.checkCount > 0 }
        assets.arrive()

        // What the iPhone showed: the model installed, the request silent. The caller must not
        // wait out its whole timeout with the model already there.
        #expect(try await outcome == .available)
    }

    @Test("the assets are checked only while someone waits")
    func checkRunsOnlyWhileWaited() async throws {
        let fake = FakeRequest()
        let assets = FakeAssets()
        let request = Self.shared(fake, key: Self.uniqueKey(), assets: assets)

        try await Task.sleep(for: Self.checkInterval * 5)
        let beforeWaiting = assets.checkCount
        _ = try await request.wait(timeout: Self.checkInterval * 5)
        let whileWaiting = assets.checkCount
        try await Task.sleep(for: Self.checkInterval * 5)
        let afterWaiting = assets.checkCount

        // A request nobody waits on — such as one that will never answer — costs nothing.
        #expect(beforeWaiting == 0)
        #expect(whileWaiting > 0)
        // One check may already be under way as the last waiter leaves.
        #expect(afterWaiting - whileWaiting <= 1)
    }

    // MARK: - Staleness

    @Test("a stale request is replaced, so a retry asks again")
    func staleRequestIsSuperseded() async throws {
        let first = FakeRequest()
        let second = FakeRequest()
        let assets = FakeAssets()
        let key = Self.uniqueKey()
        let staleAfter: Duration = .milliseconds(100)

        let original = Self.shared(first, key: key, assets: assets, staleAfter: staleAfter)
        let joined = Self.shared(second, key: key, assets: assets, staleAfter: staleAfter)
        try await Task.sleep(for: staleAfter * 2)
        let replacement = Self.shared(second, key: key, assets: assets, staleAfter: staleAfter)

        // What the airplane-mode test needed: the retry joined a request that would never answer.
        #expect(joined === original)
        #expect(replacement !== original)
        try await waitUntil { second.startCount == 1 }
        second.answer(.available)
        #expect(try await replacement.wait(timeout: nil) == .available)
    }

    @Test("a superseded request's waiters are still resolved when the assets arrive")
    func supersededWaitersStillResolve() async throws {
        let first = FakeRequest()
        let second = FakeRequest()
        let assets = FakeAssets()
        let key = Self.uniqueKey()
        let staleAfter: Duration = .milliseconds(100)
        let original = Self.shared(first, key: key, assets: assets, staleAfter: staleAfter)

        async let outcome = original.wait(timeout: .seconds(30))
        try await Task.sleep(for: staleAfter * 2)
        _ = Self.shared(second, key: key, assets: assets, staleAfter: staleAfter)
        assets.arrive()

        // Abandoned, not cancelled: its check still runs for the caller it already had.
        #expect(try await outcome == .available)
    }

    @Test("a request that throws passes its error to every waiter")
    func thrownErrorReachesWaiters() async throws {
        struct Failure: Error {}
        let request = RTSRAGAssetRequest.shared(key: Self.uniqueKey()) {
            throw Failure()
        }

        await #expect(throws: Failure.self) {
            try await request.wait(timeout: .seconds(30))
        }
    }

    // MARK: - Helpers

    /// Polls `condition` until it holds, for state that a detached task changes.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
