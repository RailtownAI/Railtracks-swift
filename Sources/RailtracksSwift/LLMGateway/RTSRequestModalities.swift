//
//  RTSRequestModalities.swift
//  RailtracksSwift
//

import Foundation
import Conduit

/// What a single request actually carries, so provider settings that only mean something for one
/// modality are not sent on requests without it.
///
/// `.text` is included for completeness even though nothing keys off it today — a setting that
/// applies to text applies to every request, which is better expressed as an unconditional one. It is
/// here so the set describes the payload honestly rather than relying on "text is always present",
/// which nothing enforces: `Message.Content.parts` can hold media with no text part at all.
/// Internal: this describes a request the library assembles, and is derived from the payload rather
/// than chosen. An app has no say in it — what it controls is the content it passes to `flow.run`.
struct RTSRequestModalities: OptionSet, Sendable, Equatable {
    let rawValue: Int

    static let text = RTSRequestModalities(rawValue: 1 << 0)
    static let image = RTSRequestModalities(rawValue: 1 << 1)
    static let video = RTSRequestModalities(rawValue: 1 << 2)
    static let audio = RTSRequestModalities(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

extension RTSRequestModalities {
    /// Derives the modalities from the payload being sent.
    ///
    /// Read from the content rather than from the caller's `images` argument on purpose: those are
    /// two separate assertions about the same request, and nothing keeps them in agreement. Deriving
    /// from what actually goes on the wire means a future path that attaches media some other way is
    /// accounted for without anyone remembering to update a flag.
    init(_ content: Message.Content) {
        switch content {
        case .text:
            self = [.text]
        case .parts(let parts):
            var modalities: RTSRequestModalities = []
            for part in parts {
                switch part {
                case .text:
                    modalities.insert(.text)
                case .image:
                    modalities.insert(.image)
                case .audio:
                    modalities.insert(.audio)
                }
            }
            self = modalities
        }
    }
}
