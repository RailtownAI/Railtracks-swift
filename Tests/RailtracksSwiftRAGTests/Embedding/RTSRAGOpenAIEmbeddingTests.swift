//
//  RTSRAGOpenAIEmbeddingTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// The cloud embedder, driven through a stubbed transport.
///
/// **No key, no network, no spend.** A suite that bills the account on every CI run is a suite
/// people switch off, and the behaviour worth pinning here — request shape, error classification,
/// retry bounds — is exactly what a stub can assert and a live call cannot.
///
/// Serialized because the stub is registered process-wide on `URLProtocol`.
@Suite("RailtracksSwiftRAG OpenAI embedding", .serialized)
struct RTSRAGOpenAIEmbeddingTests {

    // MARK: - Request shape

    @Test("a batch is one request carrying every input")
    func batchIsASingleArrayRequest() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.embeddings(count: 3, tokens: 42)
        }
        let embedder = makeEmbedder()

        let result = try await embedder.embed(["one", "two", "three"])

        // The defect this whole embedder exists to avoid: Conduit sends `"input"` as a bare string,
        // one request per text, so a 1,000-chunk corpus becomes ~1,000 requests instead of two.
        #expect(StubTransport.requestCount == 1)
        let input = try #require(StubTransport.lastBody?["input"] as? [String])
        #expect(input == ["one", "two", "three"])
        #expect(result.vectors.count == 3)
    }

    @Test("the provider's own token count reaches the metrics")
    func usageIsParsed() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.embeddings(count: 2, tokens: 137)
        }

        let result = try await makeEmbedder().embed(["a", "b"])

        // Conduit never reads `usage`, which is what actually blocks cost reporting — not the
        // missing tokenizer. Our own count would not be the billed one anyway.
        #expect(result.metrics.inputTokens == 137)
        #expect(result.metrics.dimension == 4)
    }

    @Test("vectors are ordered by the response's index, not by array position")
    func vectorsAreReordered() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            // Deliberately out of order, which OpenAI's docs permit.
            let data: [[String: Any]] = [
                ["index": 1, "embedding": [9.0, 9.0]],
                ["index": 0, "embedding": [1.0, 1.0]],
            ]
            return StubTransport.json(["data": data, "model": "m"], status: 200)
        }

        let result = try await makeEmbedder().embed(["first", "second"])

        // A vector paired with the wrong chunk is silently wrong at query time and undetectable
        // afterwards — both values are well-formed, only the pairing is nonsense.
        #expect(result.vectors[0] == [1.0, 1.0])
        #expect(result.vectors[1] == [9.0, 9.0])
    }

    @Test("the tighter of the request and token budgets governs")
    func headroomTakesTheBindingBudget() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.embeddings(count: 1, tokens: 5)
        }
        // Requests are comfortable, tokens nearly spent — so the run is token-bound, and reacting
        // to the request figure alone would climb straight into a 429. Many small batches exhaust
        // RPM first, a few large ones exhaust TPM first; either can be the binding one.
        StubTransport.headers = [
            "x-ratelimit-limit-requests": "1000",
            "x-ratelimit-remaining-requests": "900",
            "x-ratelimit-limit-tokens": "1000000",
            "x-ratelimit-remaining-tokens": "20000",
        ]
        let governor = RTSRAGRateGovernor(initialLimit: 6, maximumLimit: 16, successesPerIncrease: 1)

        _ = try await makeEmbedder(governor: governor).embed(["a"])

        // 0.02 token headroom is below the floor, so a permit is shed despite 90% of requests
        // remaining.
        #expect(await governor.currentLimit == 5)
    }

    @Test("absent rate headers leave the probing loop intact")
    func missingHeadersFallBackToProbing() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.embeddings(count: 1, tokens: 5)
        }
        // A compatible gateway or self-hosted endpoint may report nothing.
        let governor = RTSRAGRateGovernor(initialLimit: 4, maximumLimit: 16, successesPerIncrease: 1)

        _ = try await makeEmbedder(governor: governor).embed(["a"])

        #expect(await governor.currentLimit == 5)
    }

    // MARK: - Classification

    @Test("429 rate_limit_exceeded and 429 insufficient_quota are told apart")
    func rateLimitAndQuotaDiffer() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.error(status: 429, code: "rate_limit_exceeded")
        }
        let limited = await makeEmbedder().embed([chunk("a")], maxAttempts: 1)

        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.error(status: 429, code: "insufficient_quota")
        }
        let exhausted = await makeEmbedder().embed([chunk("a")], maxAttempts: 1)

        // The same status code meaning opposite things. Python catches bare `Exception` and draws
        // no distinction, so an out-of-credit key buys a full retry pass on every document.
        #expect(limited.first?.failure?.kind == .rateLimited)
        #expect(exhausted.first?.failure?.kind == .quotaExhausted)
        #expect(limited.first?.failure?.kind.isWorthRetrying == true)
        #expect(exhausted.first?.failure?.kind.isWorthRetrying == false)
    }

    @Test("a 400 is permanent, a 500 is transient")
    func statusClassesDiffer() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.error(status: 400, code: "invalid_request_error")
        }
        let bad = await makeEmbedder().embed([chunk("a")], maxAttempts: 1)

        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.error(status: 503, code: nil)
        }
        let down = await makeEmbedder().embed([chunk("a")], maxAttempts: 1)

        #expect(bad.first?.failure?.kind == .invalidInput)
        #expect(down.first?.failure?.kind == .transient)
    }

    // MARK: - Failure handling

    @Test("a permanent failure is still recorded, never dropped")
    func permanentFailuresAreRecorded() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.error(status: 400, code: "invalid_request_error")
        }

        let outcomes = await makeEmbedder().embed([chunk("a")], batchSize: 1)

        // Pre-filtering the unretryable ones is the tempting shortcut and loses the failures a
        // human most needs to see. Classification is a label, not a filter.
        let failure = try #require(outcomes.first?.failure)
        #expect(failure.chunks.count == 1)
        #expect(failure.underlying.contains("invalid_request_error"))
        #expect(failure.modelIdentifier == "openai/text-embedding-3-small")
    }

    @Test("one rejected chunk is isolated instead of taking its batch down")
    func invalidInputIsBisected() async throws {
        StubTransport.reset()
        // Only the request carrying "poison" is refused; anything else embeds.
        StubTransport.respond { _ in
            let inputs = StubTransport.lastBody?["input"] as? [String] ?? []
            guard inputs.contains("poison") else {
                return StubTransport.embeddings(count: inputs.count, tokens: inputs.count)
            }
            return StubTransport.error(status: 400, code: "invalid_request_error")
        }

        let chunks = ["a", "b", "poison", "d", "e", "f", "g", "h"].map { chunk($0) }
        let outcomes = await makeEmbedder().embed(chunks, batchSize: 8)

        // Without the split, one bad chunk denies the other seven — and against OpenAI's array
        // request that is up to 512, which the phase 6 commit rule would turn into a lost
        // document. Python heads this off with a tokenizer it has and this module cannot.
        let embedded = outcomes.flatMap { $0.embeddedChunks }
        let failures = outcomes.compactMap { $0.failure }
        #expect(embedded.count == 7)
        #expect(failures.count == 1)
        #expect(failures.first?.chunks.map { $0.content } == ["poison"])
    }

    @Test("a rate limit is not bisected, because it is not about the content")
    func rateLimitIsNotBisected() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.error(status: 429, code: "insufficient_quota")
        }

        let chunks = ["a", "b", "c", "d"].map { chunk($0) }
        let outcomes = await makeEmbedder().embed(chunks, batchSize: 4)

        // Splitting here would double the requests while the account is already refusing them,
        // and would report four failures where there is one condition.
        #expect(StubTransport.requestCount == 1)
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.failure?.chunks.count == 4)
    }

    @Test("one failing batch does not take the others down")
    func failureIsIsolatedToItsBatch() async throws {
        StubTransport.reset()
        StubTransport.respond { index in
            index == 1
                ? StubTransport.error(status: 400, code: "invalid_request_error")
                : StubTransport.embeddings(count: 1, tokens: 3)
        }

        let outcomes = await makeEmbedder()
            .embed([chunk("a"), chunk("b"), chunk("c")], batchSize: 1, maxAttempts: 1)

        #expect(outcomes.count == 3)
        #expect(outcomes[0].failure == nil)
        #expect(outcomes[1].failure != nil)
        #expect(outcomes[2].failure == nil)
    }

    @Test("a mismatched vector count fails the batch instead of mis-pairing")
    func vectorCountIsVerified() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.embeddings(count: 2, tokens: 5)   // two vectors for three inputs
        }

        let outcomes = await makeEmbedder()
            .embed([chunk("a"), chunk("b"), chunk("c")], batchSize: 3, maxAttempts: 1)

        // Without this guard every chunk after the gap silently receives its neighbour's vector —
        // well-formed data, nonsense pairing, invisible at query time.
        let failure = try #require(outcomes.first?.failure)
        #expect(failure.underlying.contains("2 vectors for 3 inputs"))
    }

    // MARK: - Retry

    @Test("a transient failure is retried once and the attempt is recorded")
    func transientFailureIsRetried() async throws {
        StubTransport.reset()
        StubTransport.respond { index in
            index == 0
                ? StubTransport.error(status: 429, code: "rate_limit_exceeded")
                : StubTransport.embeddings(count: 1, tokens: 7)
        }

        let outcomes = await makeEmbedder().embed([chunk("a")], batchSize: 1)

        #expect(StubTransport.requestCount == 2)
        #expect(outcomes.first?.failure == nil)
        #expect(outcomes.first?.embeddedChunks.count == 1)
    }

    @Test("a permanent failure is not retried at all")
    func permanentFailureSkipsTheRetry() async throws {
        StubTransport.reset()
        StubTransport.respond { _ in
            StubTransport.error(status: 429, code: "insufficient_quota")
        }

        let outcomes = await makeEmbedder().embed([chunk("a")], batchSize: 1)

        // The half worth pinning: an out-of-credit key would otherwise buy a second full pass over
        // every document in the corpus, for nothing.
        #expect(StubTransport.requestCount == 1)
        #expect(outcomes.first?.failure?.attempts == 1)
        #expect(outcomes.first?.failure?.kind == .quotaExhausted)
    }

    // MARK: - Helpers

    private func makeEmbedder(
        governor: RTSRAGRateGovernor = RTSRAGRateGovernor(initialLimit: 2)
    ) -> RTSRAGOpenAIEmbedding {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return RTSRAGOpenAIEmbedding(
            apiKey: "test-key",
            batchSize: 512,
            governor: governor,
            session: URLSession(configuration: configuration)
        )
    }

    private func chunk(_ content: String) -> RTSRAGChunk {
        RTSRAGChunk(content: content, documentID: RTSRAGDocumentID(UUID()), index: 0)
    }
}

// MARK: - StubTransport

/// A `URLProtocol` that answers embedding requests from a per-test handler and records what it saw.
final class StubTransport: URLProtocol, @unchecked Sendable {

    private struct State {
        var handler: (@Sendable (Int) -> (Data, Int))?
        var requestCount = 0
        var lastBody: [String: Any]?
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset() {
        lock.lock()
        state = State()
        lock.unlock()
    }

    /// The handler receives the zero-based request index, so a test can fail the first call and
    /// succeed the second without any shared counter of its own.
    static func respond(_ handler: @escaping @Sendable (Int) -> (Data, Int)) {
        lock.lock()
        state.handler = handler
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return state.requestCount
    }

    static var lastBody: [String: Any]? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return state.lastBody
    }

    /// Extra response headers, for the rate-budget cases. Cleared by `reset()`.
    static var headers: [String: String] {
        get {
            lock.lock()
            defer {
                lock.unlock()
            }
            return state.headers
        }
        set {
            lock.lock()
            state.headers = newValue
            lock.unlock()
        }
    }

    // MARK: Response builders

    static func json(_ object: [String: Any], status: Int) -> (Data, Int) {
        (try! JSONSerialization.data(withJSONObject: object), status)
    }

    static func embeddings(count: Int, tokens: Int) -> (Data, Int) {
        let data = (0..<count).map { index in
            ["index": index, "embedding": [0.1, 0.2, 0.3, Double(index)]] as [String: Any]
        }
        return json(
            [
                "data": data,
                "model": "text-embedding-3-small",
                "usage": ["prompt_tokens": tokens, "total_tokens": tokens],
            ],
            status: 200
        )
    }

    static func error(status: Int, code: String?) -> (Data, Int) {
        var error: [String: Any] = ["message": "stubbed failure"]
        if let code {
            error["code"] = code
        }
        return json(["error": error], status: status)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        StubTransport.lock.lock()
        let index = StubTransport.state.requestCount
        StubTransport.state.requestCount += 1
        // URLSession may move a body into a stream before it reaches here, so read both.
        let body = request.httpBody ?? StubTransport.drain(request.httpBodyStream)
        if let body {
            StubTransport.state.lastBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        let handler = StubTransport.state.handler
        let extraHeaders = StubTransport.state.headers
        StubTransport.lock.unlock()

        let (data, status) = handler?(index) ?? StubTransport.embeddings(count: 1, tokens: 1)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(extraHeaders) { _, new in new }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
    }

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else {
            return nil
        }
        stream.open()
        defer {
            stream.close()
        }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}
