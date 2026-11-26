//
//  NodeIdentityTests.swift
//  RailtracksSwiftTests
//
//  `RTSNodeIdentity.current`: tells code running inside a node which session, run and node it is
//  in, with the IDs the flow's trace and events use. Read-only: only the invoker binds it.
//

import Foundation
import Synchronization
import Testing
@testable import RailtracksSwift

/// An orchestrator whose body is a closure, so a test can look around from inside a running node.
private struct ProbeOrchestrator: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName: String
    let body: @Sendable (RTSInput, RTSRunContext) async throws -> RTSOutput

    func name() -> String {
        nodeName
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        try await body(input, context)
    }
}

/// A tool whose closure records what it sees, for invoking without a flow.
private struct ProbeTool: RTSToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName = "Probe"
    let toolDescription = "records the node identity it runs under"
    let parameterSchema = RTSToolSchema(parameters: [])
    let callableRoutine: RTSClosure

    init(sightings: Sightings) {
        callableRoutine = RTSClosure { _ in
            sightings.record("tool")
            return [:]
        }
    }
}

/// What a probe saw: the identity and, to compare, the invoker's own task-local.
private struct Sighting: Sendable {
    let node: RTSNodeIdentity?
    let invocationID: UUID?
}

private final class Sightings: Sendable {
    private let seen = Mutex<[String: Sighting]>([:])

    func record(_ name: String) {
        record(name, node: RTSNodeIdentity.current)
    }

    func record(_ name: String, node: RTSNodeIdentity?) {
        let sighting = Sighting(
            node: node,
            invocationID: RTSNodeInvoker.currentInvocationID
        )
        seen.withLock { $0[name] = sighting }
    }

    subscript(name: String) -> Sighting? {
        seen.withLock { $0[name] }
    }
}

extension RailtracksSwiftTestSuite {
    @Suite("Current node identity")
    struct NodeIdentityTests {

        @Test("Outside a node there is no current node")
        func noCurrentNodeOutside() {
            #expect(RTSNodeIdentity.current == nil)
        }

        @Test("Inside a node, the identity names the flow's session, the run and the node")
        func currentNodeInside() async throws {
            let sightings = Sightings()
            let child = ProbeOrchestrator(nodeName: "Child") { _, _ in
                sightings.record("child")
                return [:]
            }
            let root = ProbeOrchestrator(nodeName: "Root") { _, context in
                sightings.record("root")
                _ = try await context.call(child, input: [:])
                return [:]
            }
            let flow = RTSFlow(title: "NodeIdentity",savesTrace: false, emitsSignposts: false)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let rootNode = try #require(sightings["root"]?.node)
            let childNode = try #require(sightings["child"]?.node)
            #expect(rootNode.sessionID == flow.id)
            #expect(childNode.sessionID == flow.id)
            #expect(rootNode.nodeID == sightings["root"]?.invocationID)
            #expect(childNode.nodeID == sightings["child"]?.invocationID)
            #expect(rootNode.nodeID != childNode.nodeID)
            #expect(rootNode.runID != childNode.runID)
            #expect(rootNode.runID != rootNode.nodeID)
        }

        @Test("A node invoked without a flow has no identity")
        func noIdentityWithoutAFlow() async throws {
            let sightings = Sightings()
            let invoker = RTSNodeInvoker()

            _ = try await invoker.invokeTool(ProbeTool(sightings: sightings), input: [:])

            let sighting = try #require(sightings["tool"])
            #expect(sighting.invocationID != nil)
            #expect(sighting.node == nil)
        }

        @Test("A detached task started inside a node doesn't inherit its identity")
        func detachedTaskHasNoIdentity() async throws {
            let sightings = Sightings()
            let root = ProbeOrchestrator(nodeName: "Root") { _, _ in
                sightings.record("root")
                let detached = await Task.detached {
                    RTSNodeIdentity.current
                }.value
                sightings.record("detached", node: detached)
                return [:]
            }
            let flow = RTSFlow(title: "DetachedIdentity", savesTrace: false, emitsSignposts: false)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            #expect(sightings["root"]?.node != nil)
            let detached = try #require(sightings["detached"])
            #expect(detached.node == nil)
        }
    }
}
