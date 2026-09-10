//
//  RTSEventScope.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSEventScope

/// The kind of scope an ``RTSEvent`` is attached to.
///
/// Mirrors the Python engine's `SCOPE_SESSION` / `SCOPE_RETRIEVAL` / `SCOPE_EVALUATION`
/// module constants (`observability/models.py`); the raw values are the wire values.
public enum RTSEventScope: String, Sendable, Codable {
    case session
    case retrieval
    case evaluation
}
