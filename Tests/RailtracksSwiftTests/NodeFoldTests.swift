//
//  NodeFoldTests.swift
//  RailtracksSwift
//

import Foundation
import Testing
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {

    /// `RTSNodeFold`: the per-node state the flow-graph collector and the signpost writer both
    /// build from a node's events, so the trace and Instruments can't disagree about a node.
    @Suite("Node fold")
    struct NodeFoldTests {

        private static let nodeID = "node-1"
        private static let stamp = Date(timeIntervalSince1970: 1_788_000_000)

        private func fold() -> RTSNodeFold {
            RTSNodeFold(
                creation: RTSNodeCreationEvent(nodeID: Self.nodeID, name: "Agent", nodeType: .agent)
            )
        }

        private func invocation(
            parentNodeID: String?,
            kwargs: RTSInput = ["prompt": .string("hi")],
            runID: RTSRunID? = UUID()
        ) -> RTSNodeInvocationEvent {
            RTSNodeInvocationEvent(
                parent: .node(nodeID: Self.nodeID),
                spatialParent: .node(nodeID: parentNodeID),
                kwargs: kwargs,
                runID: runID
            )
        }

        private func inputGuardResponse(
            _ decision: RTSGuardrailDecision
        ) -> RTSGuardInputResponseEvent {
            RTSGuardInputResponseEvent(
                parent: .middleware(middlewareTypeID: "rail", middlewareInvokeID: "rail-run"),
                spatialParent: .nodeAndMiddleware(nodeID: Self.nodeID, middlewareInvokeID: nil),
                messageHistory: [:],
                decision: decision
            )
        }

        private func message(_ role: RTSMessage.Role, _ text: String) -> RTSMessage {
            RTSMessage(
                id: UUID(),
                role: role,
                content: .text(text),
                timestamp: Self.stamp,
                metadata: nil,
                runID: nil
            )
        }

        private func destruction(
            response: RTSValue?,
            failure: RTSEventFailureDetails? = nil
        ) -> RTSNodeDestructionEvent {
            RTSNodeDestructionEvent(
                parent: .node(nodeID: Self.nodeID),
                spatialParent: .node(nodeID: nil),
                response: response,
                durationSeconds: 1,
                failure: failure
            )
        }

        // MARK: - Routing

        @Test("Every node-scoped event is routed to the node it belongs to")
        func routesNodeScopedEvents() {
            let llmParent = RTSEventParent.llm(llmTypeID: "model", llmInvokeID: "call")
            let railParent = RTSEventParent.middleware(
                middlewareTypeID: "rail",
                middlewareInvokeID: "rail-run"
            )
            let band = RTSEventSpatialParent.nodeAndMiddleware(
                nodeID: Self.nodeID,
                middlewareInvokeID: nil
            )
            let events: [any RTSObservabilityEvent] = [
                RTSNodeCreationEvent(nodeID: Self.nodeID, name: "Agent", nodeType: .agent),
                invocation(parentNodeID: "caller"),
                inputGuardResponse(RTSGuardrailDecision(action: .allow, reason: "")),
                RTSGuardInputFailureEvent(
                    parent: railParent,
                    spatialParent: band,
                    exceptionName: "E",
                    exceptionMessage: "m"
                ),
                RTSGuardOutputResponseEvent(
                    parent: railParent,
                    spatialParent: band,
                    response: [:],
                    decision: RTSGuardrailDecision(action: .allow, reason: "")
                ),
                RTSGuardOutputFailureEvent(
                    parent: railParent,
                    spatialParent: band,
                    exceptionName: "E",
                    exceptionMessage: "m"
                ),
                RTSLLMResponseEvent(
                    parent: llmParent,
                    spatialParent: .node(nodeID: Self.nodeID),
                    messageInput: [],
                    output: nil
                ),
                RTSLLMFailureEvent(
                    parent: llmParent,
                    spatialParent: .node(nodeID: Self.nodeID),
                    messageInput: [],
                    exceptionName: "E",
                    exceptionMessage: "m"
                ),
                destruction(response: nil),
            ]
            for event in events {
                #expect(RTSNodeFold.nodeID(of: event) == Self.nodeID, "\(event.eventType)")
            }
        }

        @Test("An event with no node to name is routed nowhere")
        func routesUnnamedEventsNowhere() {
            let unnamed = RTSLLMResponseEvent(
                parent: .llm(llmTypeID: "model", llmInvokeID: "call"),
                spatialParent: .node(nodeID: nil),
                messageInput: [],
                output: nil
            )
            #expect(RTSNodeFold.nodeID(of: unnamed) == nil)
            let session = RTSLLMCreationEvent(llmID: "call", modelProvider: "p", modelName: "m")
            #expect(RTSNodeFold.nodeID(of: session) == nil)
        }

        // MARK: - Invocation

        @Test("node.invocation sets the parent, the run id and the input")
        func invocationSetsParentRunAndInput() {
            var fold = fold()
            let runID = UUID()
            fold.apply(invocation(parentNodeID: "caller", runID: runID))
            #expect(fold.parentNodeID == "caller")
            #expect(fold.runID == runID)
            #expect(fold.input == ["prompt": .string("hi")])
        }

        @Test("A root's node.invocation leaves the parent nil")
        func rootInvocationHasNoParent() {
            var fold = fold()
            fold.apply(invocation(parentNodeID: nil))
            #expect(fold.parentNodeID == nil)
            #expect(fold.runID != nil)
        }

        @Test("A node.invocation with no run id is ignored")
        func invocationWithoutRunIDIsIgnored() {
            var fold = fold()
            fold.apply(invocation(parentNodeID: "caller", runID: nil))
            #expect(fold.runID == nil)
            #expect(fold.parentNodeID == nil)
            #expect(fold.input.isEmpty)
        }

        // MARK: - Input guard transforms

        @Test("An input guard transform replaces the input; an allow keeps it")
        func inputGuardTransformReplacesInput() {
            var fold = fold()
            fold.apply(invocation(parentNodeID: nil))
            fold.apply(inputGuardResponse(RTSGuardrailDecision(action: .allow, reason: "")))
            #expect(fold.input == ["prompt": .string("hi")])

            fold.apply(
                inputGuardResponse(
                    RTSGuardrailDecision(
                        action: .transform,
                        reason: "",
                        transformedValue: .object(["prompt": .string("[redacted]")])
                    )
                )
            )
            #expect(fold.input == ["prompt": .string("[redacted]")])
        }

        // MARK: - Messages

        @Test("The latest llm.response's input and output are the call's messages")
        func llmResponseSetsMessages() {
            var fold = fold()
            let parent = RTSEventParent.llm(llmTypeID: "model", llmInvokeID: "call")
            let first = [message(.user, "hi")]
            let reply = message(.assistant, "hello")
            fold.apply(
                RTSLLMResponseEvent(
                    parent: parent,
                    spatialParent: .node(nodeID: Self.nodeID),
                    messageInput: first,
                    output: reply
                )
            )
            #expect(fold.messages.map(\.id) == (first + [reply]).map(\.id))

            let followUp = first + [reply, message(.user, "again")]
            fold.apply(
                RTSLLMResponseEvent(
                    parent: parent,
                    spatialParent: .node(nodeID: Self.nodeID),
                    messageInput: followUp,
                    output: nil
                )
            )
            #expect(fold.messages.map(\.id) == followUp.map(\.id))
        }

        @Test("An llm.failure's input is the call's messages")
        func llmFailureSetsMessages() {
            var fold = fold()
            let input = [message(.user, "hi"), message(.assistant, "partial")]
            fold.apply(
                RTSLLMFailureEvent(
                    parent: .llm(llmTypeID: "model", llmInvokeID: "call"),
                    spatialParent: .node(nodeID: Self.nodeID),
                    messageInput: input,
                    exceptionName: "E",
                    exceptionMessage: "m"
                )
            )
            #expect(fold.messages.map(\.id) == input.map(\.id))
        }

        // MARK: - Output

        @Test("The output is a successful destruction's object response, and nil otherwise")
        func outputOfDestruction() {
            let response = RTSValue.object(["sum": .number(3)])
            #expect(RTSNodeFold.output(of: destruction(response: response)) == ["sum": .number(3)])
            #expect(RTSNodeFold.output(of: destruction(response: .string("3"))) == nil)
            #expect(RTSNodeFold.output(of: destruction(response: nil)) == nil)
            let failure = RTSEventFailureDetails(CancellationError())
            let failed = destruction(response: response, failure: failure)
            #expect(RTSNodeFold.output(of: failed) == nil)
        }
    }
}
