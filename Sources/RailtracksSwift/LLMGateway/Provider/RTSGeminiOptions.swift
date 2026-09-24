//
//  RTSGeminiOptions.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-24.
//

import Foundation

/// Per-image token budget for Gemini vision input.
///
/// Both Gemini 3 and 2.5 honor this, but each level costs differently per family *and* the families
/// default to different levels — so moving an agent between them changes its image cost without any
/// code change. Per-image tokens, measured against `:countTokens`:
///
/// | Family | `.low` | `.medium` | `.high` |
/// |---|---|---|---|
/// | Gemini 3.x | 252 | 558 | **1075** (default) |
/// | Gemini 2.5 | 66 | **258** (default) | scales with image size |
///
/// On Gemini 3 every level is a flat allocation — a 300px thumbnail and a 3072px photo both cost the
/// level's figure, because the image is resampled to fit the budget. The same holds for `.low` and
/// `.medium` on 2.5. The one exception is `.high` on 2.5, which tiles: 258 tokens for an image within
/// 384px on both sides, rising with dimensions (2322 measured at 3072×1786). Only there does image
/// size drive cost, and it is not reliably predictable from Google's published tiling formula —
/// measure it for the sizes you actually send.
///
/// Lowering the level is a cost and context-budget lever for work that does not need fine detail; the
/// ceiling matters for OCR, dense charts, and small objects. Note that on Gemini 3 a small image at
/// `.high` still costs the full 1075 — the budget is charged whether the image can use it or not.
///
/// Google also documents an `ultra_high` level. It is deliberately not offered here: `v1beta` rejects
/// it with HTTP 400 on every Gemini model tested, Flash and Pro, 3.x and 2.5 alike. Conduit keeps the
/// case so the value stays reachable if Google enables it; RailtracksSwift does not expose it.
public enum RTSGeminiMediaResolution: String, Sendable, Equatable {
    case low
    case medium
    case high
}

/// Settings that exist only on Gemini.
///
/// These live in the `.gemini` case's associated value rather than on `RTSAgent` so that swapping an
/// agent to another provider discards them *by construction* — there is nowhere on `.openAI` or
/// `.anthropic` to put them. A shared options bag would instead survive the swap and silently do
/// nothing, which is the failure this shape is chosen to prevent.
public struct RTSGeminiOptions: Sendable, Equatable {
    /// Per-image token budget for vision input. `nil` leaves the model default in place.
    public var mediaResolution: RTSGeminiMediaResolution?

    public init(mediaResolution: RTSGeminiMediaResolution? = nil) {
        self.mediaResolution = mediaResolution
    }
}
