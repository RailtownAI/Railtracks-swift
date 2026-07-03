//
//  RTSOrchestratorTool.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-07-02.
//

import Foundation

/// Wraps an `RTSOrchestratorNode` so it can be registered as a tool on a parent agent.
/// When the parent LLM decides to call this tool, the orchestrator runs with an
/// `RTSRunContext` (parented to the calling agent) and its output is returned as the
/// tool result. Mirrors `RTSAgentTool`, but for a function/orchestrator node.
public struct RTSOrchestratorTool: Sendable {
    var wrappedOrchestrator: any RTSOrchestratorNode
    let description: String
    let parameters: RTSToolSchema
    /// Satisfies the `RTSToolNode` protocol requirement. Not used for invocation —
    /// orchestrator tools are always dispatched through an orchestrator-tool bridge.
    public var callableRoutine: RTSClosure
    /// Optional closure run on the raw inputs before they are forwarded to the orchestrator.
    public var inputTransform: (@Sendable (RTSInput) async throws -> RTSInput)?
    /// Optional closure run on the orchestrator's outputs before they are returned to the parent LLM.
    public var outputTransform: (@Sendable (RTSOutput) async throws -> RTSOutput)?

    /// - Parameters:
    ///   - orchestrator: The orchestrator node to expose as a callable tool.
    ///   - description: Human-readable description shown to the parent LLM when deciding whether to call this tool.
    ///   - parameters: Schema describing the tool's input parameters.
    ///   - inputTransform: Optional closure to rewrite inputs before they reach the orchestrator.
    ///   - outputTransform: Optional closure to rewrite the orchestrator's output.
    public init(
        orchestrator: any RTSOrchestratorNode,
        description: String,
        parameters: RTSToolSchema,
        inputTransform: (@Sendable (RTSInput) async throws -> RTSInput)? = nil,
        outputTransform: (@Sendable (RTSOutput) async throws -> RTSOutput)? = nil
    ) {
        self.wrappedOrchestrator = orchestrator
        self.description = description
        self.parameters = parameters
        self.callableRoutine = RTSClosure { _ in [:] }
        self.inputTransform = inputTransform
        self.outputTransform = outputTransform
    }
}

extension RTSOrchestratorTool: RTSToolNode {
    public var id: UUID {
        wrappedOrchestrator.id
    }

    public var toolName: String {
        wrappedOrchestrator.name()
    }

    public var inputs: RTSInput {
        get { wrappedOrchestrator.inputs }
        set { wrappedOrchestrator.inputs = newValue }
    }

    public var toolDescription: String {
        description
    }

    public var parameterSchema: RTSToolSchema {
        parameters
    }

    /// Orchestrator tools are dispatched through an orchestrator-tool bridge, never
    /// directly through the plain `RTSToolNode` path.
    public func invoke(runID: UUID) async throws -> RTSOutput {
        throw RTSError.invalidInvocation(
            "RTSOrchestratorTool must be invoked via an orchestrator-tool bridge, not directly through RTSToolNode"
        )
    }
}
