//
//  RTSEventTimestamp.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSEventTimestamp

/// Clock and wire format for observability event timestamps.
///
/// Mirrors the Python engine's `Timestamp` namespace helper (`observability/models.py`).
/// Python stamps events with a timezone-aware UTC `datetime` and serializes it with
/// `datetime.isoformat()`, which produces six fractional digits and an explicit `+00:00`
/// offset — `2026-09-04T12:34:56.789012+00:00`.
///
/// `ISO8601DateFormatter` cannot produce that: it emits three fractional digits and a `Z`.
/// So the string is assembled here by hand.
///
/// One accepted divergence: Python's `isoformat()` omits the fractional part entirely when
/// `microsecond == 0`; this always writes six digits.
public enum RTSEventTimestamp {

    /// The current instant, in UTC. Mirrors Python's `Timestamp.now()`.
    public static func now() -> Date {
        Date()
    }

    /// Formats `date` the way Python's `datetime.isoformat()` formats a UTC-aware value.
    public static func isoString(from date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var wholeSeconds = interval.rounded(.down)
        var microseconds = Int(((interval - wholeSeconds) * 1_000_000).rounded())
        // Rounding can carry into the next second; keep the two parts consistent.
        if microseconds >= 1_000_000 {
            microseconds -= 1_000_000
            wholeSeconds += 1
        }
        let secondsPart = secondsFormatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        let fractionPart = String(format: "%06d", microseconds)
        return "\(secondsPart).\(fractionPart)+00:00"
    }

    /// Parses a string produced by ``isoString(from:)``, and tolerates the neighbouring
    /// spellings Python can emit (`Z` offset, absent or shorter fractional part).
    public static func date(from string: String) -> Date? {
        var remainder = Substring(string)

        // Skip the date-and-time part, so the date's own hyphens are not read as an offset.
        let offsetSeparator = remainder.dropFirst(19).firstIndex {
            $0 == "+" || $0 == "-" || $0 == "Z"
        }
        var offset: TimeInterval = 0
        if let offsetSeparator {
            offset = offsetSeconds(in: remainder[offsetSeparator...])
            remainder = remainder[..<offsetSeparator]
        }

        var fraction: TimeInterval = 0
        if let dotIndex = remainder.firstIndex(of: ".") {
            let digits = remainder[remainder.index(after: dotIndex)...]
            if let value = Double("0.\(digits)") {
                fraction = value
            }
            remainder = remainder[..<dotIndex]
        }

        guard let seconds = secondsFormatter.date(from: String(remainder)) else {
            return nil
        }
        return seconds.addingTimeInterval(fraction - offset)
    }

    /// Seconds east of UTC for a trailing `Z`, `+HH:MM` or `-HH:MM`.
    private static func offsetSeconds(in text: Substring) -> TimeInterval {
        guard let sign = text.first, sign != "Z" else {
            return 0
        }
        let digits = text.dropFirst().split(separator: ":")
        guard let hours = digits.first.flatMap({ Double($0) }) else {
            return 0
        }
        let minutes = digits.count > 1 ? (Double(digits[1]) ?? 0) : 0
        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }

    /// Whole seconds only — the fractional part and the offset are appended separately, so
    /// this never has to round-trip sub-second precision through `DateFormatter`.
    private static let secondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}
