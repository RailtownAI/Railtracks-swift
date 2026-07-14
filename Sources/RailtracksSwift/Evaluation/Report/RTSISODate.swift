//
//  RTSISODate.swift
//  RailtracksSwift
//

import Foundation

/// A report timestamp: stored as an epoch `TimeInterval` in memory (consistent with the
/// flow-trace format), but (de)serialized as an ISO-8601 microsecond UTC string
/// (e.g. "2026-06-15T16:35:26.817078Z") to match the Python report the visualizer consumes.
/// Uses a custom microsecond-aware codec because Foundation's `ISO8601DateFormatter`
/// truncates 6-digit fractional seconds to milliseconds.
public struct RTSISODate: Codable, Sendable, Equatable {
    /// Seconds since the Unix epoch (UTC).
    public let epoch: TimeInterval

    public init(epoch: TimeInterval) {
        self.epoch = epoch
    }
    public init(_ date: Date) {
        self.epoch = date.timeIntervalSince1970
    }

    public var date: Date {
        Date(timeIntervalSince1970: epoch)
    }

    // Whole-seconds calendar formatter in UTC; fractional part handled manually
    // so we keep full microsecond precision.
    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let epoch = Self.parse(raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not an ISO-8601 date: \(raw)"))
        }
        self.epoch = epoch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.format(epoch))
    }

    /// epoch → "yyyy-MM-dd'T'HH:mm:ss.ffffffZ" (UTC, 6 fractional digits).
    static func format(_ epoch: TimeInterval) -> String {
        let whole = floor(epoch)
        var micros = Int(((epoch - whole) * 1_000_000).rounded())
        var seconds = whole
        if micros >= 1_000_000 { micros -= 1_000_000; seconds += 1 }   // rounding carry
        let base = secondsFormatter.string(from: Date(timeIntervalSince1970: seconds))
        return "\(base).\(String(format: "%06d", micros))Z"
    }

    /// ISO-8601 (with or without fractional seconds, trailing Z) → epoch seconds.
    static func parse(_ s: String) -> TimeInterval? {
        var str = s
        if str.hasSuffix("Z") { str.removeLast() }
        let base: Substring
        var fraction: TimeInterval = 0
        if let dot = str.firstIndex(of: ".") {
            base = str[str.startIndex..<dot]
            let fracDigits = str[str.index(after: dot)...]
            if let fracValue = Double("0." + fracDigits) { fraction = fracValue }
        } else {
            base = str[...]
        }
        guard let date = secondsFormatter.date(from: String(base)) else { return nil }
        return date.timeIntervalSince1970 + fraction
    }
}
