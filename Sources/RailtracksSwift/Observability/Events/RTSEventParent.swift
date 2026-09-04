//
//  RTSEventParent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSEventSpatialParentType

/// Discriminator for ``RTSEventSpatialParent``.
///
/// Mirrors the Python engine's `SpatialType` (`events/_base.py`); the raw values are the
/// wire values.
public enum RTSEventSpatialParentType: String, Sendable, Codable {
    case middleware
    case node
    case nodeAndMiddleware = "node_and_middleware"
    case llmAndMiddleware = "llm_and_middleware"
    /// Python's `SpatialType.NONE`. Named `noParent` here so it does not collide with
    /// `Optional.none` at call sites; the wire value is unchanged.
    case noParent = "none"
}

// MARK: - RTSEventSpatialParent

/// The scope an event was emitted *from* — its caller.
///
/// Mirrors the Python engine's `SpatialParent` union (`events/_base.py`). Each case carries
/// exactly the fields its Python counterpart declares, and ``encodedFields()`` emits exactly
/// the keys that class's `asdict()` produces — not the union of every case's keys.
public enum RTSEventSpatialParent: Sendable, Equatable {
    /// `NoSpatialParent` — the event is the root of the tree.
    case noParent
    /// `MiddlewareSpatialParent`.
    case middleware(middlewareInvokeID: String)
    /// `NodeSpatialParent`. `nodeID` is `nil` for a top-level node, which has no caller.
    case node(nodeID: String?)
    /// `NodeAndMiddlewareSpatialParent`.
    case nodeAndMiddleware(nodeID: String, middlewareInvokeID: String?)
    /// `LLMAndMiddlewareSpatialParent`.
    case llmAndMiddleware(llmInvokeID: String, middlewareInvokeID: String?)

    public var type: RTSEventSpatialParentType {
        switch self {
        case .noParent:
            return .noParent
        case .middleware:
            return .middleware
        case .node:
            return .node
        case .nodeAndMiddleware:
            return .nodeAndMiddleware
        case .llmAndMiddleware:
            return .llmAndMiddleware
        }
    }

    /// The fields this case contributes, unprefixed. The caller prefixes them with
    /// `spatial_parent_`, mirroring Python's `flatten` field metadata.
    func encodedFields() -> [String: RTSValue] {
        var fields: [String: RTSValue] = ["type": .string(type.rawValue)]
        switch self {
        case .noParent:
            break
        case .middleware(let middlewareInvokeID):
            fields["middleware_invoke_id"] = .string(middlewareInvokeID)
        case .node(let nodeID):
            fields["node_id"] = .nullable(nodeID)
        case .nodeAndMiddleware(let nodeID, let middlewareInvokeID):
            fields["node_id"] = .string(nodeID)
            fields["middleware_invoke_id"] = .nullable(middlewareInvokeID)
        case .llmAndMiddleware(let llmInvokeID, let middlewareInvokeID):
            fields["llm_invoke_id"] = .string(llmInvokeID)
            fields["middleware_invoke_id"] = .nullable(middlewareInvokeID)
        }
        return fields
    }
}

// MARK: - RTSEventParentType

/// Discriminator for ``RTSEventParent``.
///
/// Mirrors the Python engine's `ParentType` (`events/_base.py`).
public enum RTSEventParentType: String, Sendable, Codable {
    case node
    case middleware
    case llm
}

// MARK: - RTSEventParent

/// The entity an event is *about*.
///
/// Mirrors the Python engine's `Parent` union (`events/_base.py`). The `middleware` and
/// `llm` cases have no Swift emit site yet — Swift has no middleware layer, and the LLM
/// event family is out of scope for now — but they are part of the union's shape.
public enum RTSEventParent: Sendable, Equatable {
    /// `NodeParent`.
    case node(nodeID: String)
    /// `MiddlewareParent`.
    case middleware(middlewareTypeID: String, middlewareInvokeID: String)
    /// `LLMParent`.
    case llm(llmTypeID: String, llmInvokeID: String)

    public var type: RTSEventParentType {
        switch self {
        case .node:
            return .node
        case .middleware:
            return .middleware
        case .llm:
            return .llm
        }
    }

    /// The fields this case contributes, unprefixed. The caller prefixes them with `parent_`.
    func encodedFields() -> [String: RTSValue] {
        var fields: [String: RTSValue] = ["type": .string(type.rawValue)]
        switch self {
        case .node(let nodeID):
            fields["node_id"] = .string(nodeID)
        case .middleware(let middlewareTypeID, let middlewareInvokeID):
            fields["middleware_type_id"] = .string(middlewareTypeID)
            fields["middleware_invoke_id"] = .string(middlewareInvokeID)
        case .llm(let llmTypeID, let llmInvokeID):
            fields["llm_type_id"] = .string(llmTypeID)
            fields["llm_invoke_id"] = .string(llmInvokeID)
        }
        return fields
    }
}
