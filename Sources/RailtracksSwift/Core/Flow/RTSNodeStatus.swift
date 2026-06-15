//
//  RTSNodeStatus.swift
//  RailtracksSwift
//

import Foundation

/// Emitted by `RTSFlow.nodeStatusPublisher` as each node transitions through its lifecycle.
public struct RTSNodeStatus: Sendable {
    public enum State: Sendable {
        case executing
        case completed
        case failed(String)
    }
    public let nodeID: UUID
    public let nodeName: String
    public let nodeType: RTSFlowNodeType
    public let state: State
    public let runID: UUID?
}
