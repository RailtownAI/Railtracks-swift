//
//  RTSIdentifiers.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-08.
//

import Foundation

// Two `UUID`s travel together through a node invocation and are easy to confuse, so they are
// named and contrasted here rather than left as bare `UUID` at each site.
//
// |                     | Identifies                        | Reaches                          |
// |---------------------|-----------------------------------|----------------------------------|
// | ``RTSInvocationID`` | the node as a *graph* record      | node/edge events, parentage      |
// | ``RTSRunID``        | the *message-tracing* key         | sessions, messages, the collector|
//
// Both are minted per call in `RTSNodeInvoker.invokeCore`, and deliberately kept separate:
// `runID` already doubles as the root edge's id, so overloading it with graph identity was
// rejected when per-invocation node ids were introduced (see `docs/duplicate-node-id.md`).
//
// These are aliases, not wrappers, so the compiler will not stop one being passed where the
// other belongs. They document intent; they do not enforce it.

/// Identifies one *invocation* of a node — its identity in the run graph.
///
/// Minted fresh per call, so a node invoked N times yields N distinct records and N edges,
/// matching the Python engine. The node *instance*'s own `id` is not used for tracing.
/// Carried down the task tree on `RTSNodeInvoker.currentInvocationID` so a child invocation
/// can name its caller without threading a parameter through provider tool-calling code.
///
/// Internal, unlike ``RTSRunID``: nothing public takes or returns one. Invocation ids *do*
/// reach clients — `RTSNodeStatus.nodeID` and `.parentNodeID` are both invocation ids — but
/// those are declared as plain `UUID`, so promoting this would be an API change to make
/// deliberately rather than a side effect of naming the concept.
internal typealias RTSInvocationID = UUID

/// Keys the messages an invocation produced back to that invocation.
///
/// Threaded into `RTSLLMSession.run(_:runID:)`, stamped onto every ``RTSMessage`` the call
/// yields, and used by the collector to attach messages to the right node. Also serves as the
/// root edge's id when a node has no caller.
public typealias RTSRunID = UUID
