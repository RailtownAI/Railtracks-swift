//
//  RTSRAGOpenAIEmbedding.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation

/// OpenAI-compatible embedding over `/v1/embeddings`.
///
/// **Calls the endpoint directly rather than through Conduit, for two measured reasons.**
/// `Conduit.OpenAIProvider+Embeddings` sends `"input"` as a bare string — one HTTP request *per
/// text*, capped at ten concurrent — so a 1,000-chunk corpus becomes ~1,000 requests where the
/// array form needs two. And it never reads the response's `usage` block, so `tokenCount` is
/// always `nil` and cost cannot be reported at all. Both are worth fixing upstream; neither should
/// block this module, which now depends on no provider SDK.
///
/// The rate limiter is composed, not built in: see ``RTSRAGRateGovernor``. Passing one governor to
/// several embedders that share an API key is deliberate — the limit is enforced per key, so two
/// embedders discovering it independently would each pay for the discovery.
///
/// `baseURL` makes Azure OpenAI and compatible gateways reachable without a second type.
public struct RTSRAGOpenAIEmbedding: RTSRAGEmbedding {

    public let modelIdentifier: String
    public let embeddingVersion: String? = nil
    /// OpenAI accepts up to 2,048 inputs per request. 512 leaves headroom and bounds the loss when
    /// a batch fails — a whole 2,048-chunk request failing is a large unit of work to redo.
    public let defaultBatchSize: Int
    /// `text-embedding-3-*` accepts 8,191 tokens, far above any chunk this library produces, so
    /// the pre-filter is left off rather than asserting a number that would never bind.
    public let maxInputCharacters: Int? = nil

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let dimensions: Int?
    private let session: URLSession
    private let governor: RTSRAGRateGovernor

    public init(
        apiKey: String,
        model: String = "text-embedding-3-small",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        dimensions: Int? = nil,
        batchSize: Int = 512,
        governor: RTSRAGRateGovernor = RTSRAGRateGovernor(),
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.dimensions = dimensions
        self.defaultBatchSize = max(1, batchSize)
        self.governor = governor
        self.session = session
        // The requested dimension count is part of the vector space: the same model truncated to
        // 256 dimensions produces vectors incomparable with its full-width output.
        self.modelIdentifier = dimensions.map { "openai/\(model)/d\($0)" } ?? "openai/\(model)"
    }

    public func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        guard !texts.isEmpty else {
            return RTSRAGTextEmbeddings(vectors: [])
        }
        let started = Date()
        let (data, response) = try await governor.withSlot {
            try await send(texts)
        }
        try await classify(response: response, body: data)
        // The provider reports its own budget on every response, successes included, so the
        // governor is told how much room is left rather than discovering it by being refused.
        await governor.recordSuccess(headroom: Self.headroom(in: response))
        return try parse(data, latency: Date().timeIntervalSince(started))
    }

    /// The smaller of the remaining request and token budgets, as a fraction of their limits.
    ///
    /// OpenAI meters **both** requests-per-minute and tokens-per-minute, and either can be the
    /// binding one: many small batches exhaust RPM first, a few large ones exhaust TPM first. Taking
    /// the minimum means the governor reacts to whichever is actually running out.
    ///
    /// `nil` when the headers are absent, which is normal for a compatible gateway or a self-hosted
    /// endpoint — the governor falls back to plain AIMD there.
    private static func headroom(in response: HTTPURLResponse) -> Double? {
        let fractions = [
            ("x-ratelimit-remaining-requests", "x-ratelimit-limit-requests"),
            ("x-ratelimit-remaining-tokens", "x-ratelimit-limit-tokens"),
        ]
        .compactMap { remainingKey, limitKey -> Double? in
            guard
                let remaining = response.value(forHTTPHeaderField: remainingKey).flatMap(Double.init),
                let limit = response.value(forHTTPHeaderField: limitKey).flatMap(Double.init),
                limit > 0
            else {
                return nil
            }
            return max(0, min(1, remaining / limit))
        }
        return fractions.min()
    }

    // MARK: - Request

    private func send(_ texts: [String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `input` is an **array**: the whole batch in one request. This is the line the module
        // exists to get right, so it is worth naming — a per-text loop here would multiply request
        // count by the batch size and trip the rate limit the governor is there to respect.
        var body: [String: Any] = [
            "model": model,
            "input": texts,
        ]
        if let dimensions {
            body["dimensions"] = dimensions
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RTSRAGEmbeddingError(kind: .transient, message: "non-HTTP response")
            }
            return (data, http)
        } catch let error as RTSRAGEmbeddingError {
            throw error
        } catch {
            await governor.recordBackoff()
            throw RTSRAGEmbeddingError(kind: .transient, message: "\(error)")
        }
    }

    /// Turns a non-200 into a classified error, and tells the governor what it means.
    ///
    /// **A 429 is two different conditions sharing a status code.** `rate_limit_exceeded` clears on
    /// backoff; `insufficient_quota` means the key is out of credit and no amount of retrying or
    /// tuning will help. Treating them alike gives an empty account a full retry pass over every
    /// document, silently — which is what Python does, catching bare `Exception`.
    private func classify(response: HTTPURLResponse, body: Data) async throws {
        guard response.statusCode != 200 else {
            return
        }
        let message = String(data: body, encoding: .utf8) ?? "status \(response.statusCode)"
        let code = Self.errorCode(in: body)
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)

        switch response.statusCode {
        case 429 where code == "insufficient_quota":
            await governor.recordFatal()
            throw RTSRAGEmbeddingError(kind: .quotaExhausted, message: message)
        case 429:
            await governor.recordBackoff(retryAfter: retryAfter)
            throw RTSRAGEmbeddingError(kind: .rateLimited, message: message)
        case 500...599:
            await governor.recordBackoff(retryAfter: retryAfter)
            throw RTSRAGEmbeddingError(kind: .transient, message: message)
        default:
            // 4xx other than 429: malformed request, bad key, input over the model's cap. The same
            // request will fail the same way forever, so it must not consume the retry budget.
            throw RTSRAGEmbeddingError(kind: .invalidInput, message: message)
        }
    }

    private static func errorCode(in body: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else {
            return nil
        }
        return error["code"] as? String
    }

    // MARK: - Response

    private func parse(_ data: Data, latency: TimeInterval) throws -> RTSRAGTextEmbeddings {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["data"] as? [[String: Any]]
        else {
            throw RTSRAGEmbeddingError(kind: .transient, message: "unreadable embeddings response")
        }
        // Sorted by the response's own index rather than trusting array order, since a vector
        // paired with the wrong chunk is silently wrong at query time and impossible to spot later.
        let ordered = items.sorted { lhs, rhs in
            (lhs["index"] as? Int ?? 0) < (rhs["index"] as? Int ?? 0)
        }
        let vectors: [[Float]] = ordered.compactMap { item in
            (item["embedding"] as? [Double])?.map { Float($0) }
        }
        guard vectors.count == items.count else {
            throw RTSRAGEmbeddingError(kind: .transient, message: "embeddings response had a malformed vector")
        }
        let usage = json["usage"] as? [String: Any]
        return RTSRAGTextEmbeddings(
            vectors: vectors,
            metrics: RTSRAGEmbeddingMetrics(
                // The provider's own count, which is what it billed. Conduit discards this, and it
                // is the reason cost reporting is impossible through that path rather than the
                // missing tokenizer — our own count would not be the authoritative one anyway.
                inputTokens: usage?["prompt_tokens"] as? Int,
                latency: latency,
                vectorCount: vectors.count,
                model: json["model"] as? String ?? modelIdentifier,
                dimension: vectors.first?.count
            )
        )
    }
}
