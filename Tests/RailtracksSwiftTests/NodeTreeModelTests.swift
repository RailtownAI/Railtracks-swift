//
//  NodeTreeModelTests.swift
//  RailtracksSwiftTests
//
//  Covers the tree assembly behind `RTSNodeTreeView`: parentage, arrival ordering, run separation,
//  collapse, and the orphan fallback.
//

import Testing
import Foundation
import RailtracksSwift
@testable import RailtracksSwiftUI

private func status(
    _ id: UUID,
    parent: UUID? = nil,
    name: String,
    type: RTSFlowNodeType = .agent,
    state: RTSNodeStatus.State = .queued
) -> RTSNodeStatus {
    RTSNodeStatus(
        nodeID: id,
        parentNodeID: parent,
        nodeName: name,
        nodeType: type,
        state: state,
        runID: nil
    )
}

private extension RTSNodeStatus.State {
    var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

@MainActor
@Suite("Node tree model")
struct NodeTreeModelTests {

    @Test("Children nest under the invocation that triggered them")
    func childrenNestUnderParent() {
        let model = RTSNodeTreeModel()
        let a = UUID()
        let b = UUID()
        model.apply(status(a, name: "Node A"))
        model.apply(status(b, parent: a, name: "Node B"))

        #expect(model.rows.map(\.item.name) == ["Node A", "Node B"])
        #expect(model.rows.map(\.depth) == [0, 1])
    }

    @Test("A node invoked twice produces two rows, not one")
    func repeatInvocationsAreDistinctRows() {
        // Per-invocation ids are what make this work — the same tool called twice arrives as two
        // different nodeIDs sharing a name.
        let model = RTSNodeTreeModel()
        let root = UUID()
        model.apply(status(root, name: "Node A"))
        model.apply(status(UUID(), parent: root, name: "Node D"))
        model.apply(status(UUID(), parent: root, name: "Node D"))

        #expect(model.rows.map(\.item.name) == ["Node A", "Node D", "Node D"])
    }

    @Test("A late child lands under its own parent, not at the end of the tree")
    func lateChildInsertsWithinItsSubtree() {
        // The ordering rule from the design: F's new child goes below F's existing children and
        // above C, rather than appending to the bottom of the whole tree.
        let model = RTSNodeTreeModel()
        let a = UUID()
        let f = UUID()
        let c = UUID()
        model.apply(status(a, name: "A"))
        model.apply(status(f, parent: a, name: "F"))
        model.apply(status(UUID(), parent: f, name: "E1"))
        model.apply(status(c, parent: a, name: "C"))
        model.apply(status(UUID(), parent: f, name: "E2"))

        #expect(model.rows.map(\.item.name) == ["A", "F", "E1", "E2", "C"])
    }

    @Test("State transitions update the existing row rather than adding one")
    func stateTransitionsMutateInPlace() {
        let model = RTSNodeTreeModel()
        let a = UUID()
        model.apply(status(a, name: "A", state: .queued))
        model.apply(status(a, name: "A", state: .executing))
        model.apply(status(a, name: "A", state: .completed))

        #expect(model.rows.count == 1)
        if case .completed = model.rows[0].item.state {
        } else {
            Issue.record("expected completed, got \(model.rows[0].item.state)")
        }
    }

    @Test("A second run starts a new root and is marked as a run boundary")
    func secondRunStartsNewRoot() {
        // Run separation is derived, not signalled: only a run's root has no parent.
        let model = RTSNodeTreeModel()
        let first = UUID()
        let second = UUID()
        model.apply(status(first, name: "Run 1 root"))
        model.apply(status(UUID(), parent: first, name: "Child"))
        model.apply(status(second, name: "Run 2 root"))

        #expect(model.rows.map(\.startsNewRun) == [false, false, true])
        #expect(model.rows.map(\.item.runIndex) == [0, 0, 1])
    }

    @Test("Collapsing hides descendants but keeps the row itself")
    func collapseHidesSubtree() {
        let model = RTSNodeTreeModel()
        let a = UUID()
        let b = UUID()
        model.apply(status(a, name: "A"))
        model.apply(status(b, parent: a, name: "B"))
        model.apply(status(UUID(), parent: b, name: "C"))

        model.toggleCollapse(b)
        #expect(model.rows.map(\.item.name) == ["A", "B"])
        #expect(model.rows[1].isCollapsed)

        model.toggleCollapse(b)
        #expect(model.rows.map(\.item.name) == ["A", "B", "C"])
    }

    @Test("A child arriving under a collapsed parent stays hidden")
    func collapseSurvivesNewChildren() {
        // Growth must not force-expand: the parent is still executing, and its spinner already says
        // work is happening. Yanking the subtree open would fight the user.
        let model = RTSNodeTreeModel()
        let a = UUID()
        let b = UUID()
        model.apply(status(a, name: "A"))
        model.apply(status(b, parent: a, name: "B"))
        model.toggleCollapse(b)
        model.apply(status(UUID(), parent: b, name: "New child"))

        #expect(model.rows.map(\.item.name) == ["A", "B"])
    }

    @Test("A node whose parent is unknown is kept, not dropped")
    func orphansAttachToTheRunRoot() {
        // Invocation-id propagation can be lost (the invoker logs an error for it). Losing the node
        // entirely would make that bug look like nothing happened.
        let model = RTSNodeTreeModel()
        let root = UUID()
        model.apply(status(root, name: "Root"))
        model.apply(status(UUID(), parent: UUID(), name: "Orphan"))

        #expect(model.rows.map(\.item.name) == ["Root", "Orphan"])
        #expect(model.rows[1].depth == 1)
    }

    @Test("Connector metadata describes the outline")
    func connectorMetadataDescribesTheOutline() {
        let model = RTSNodeTreeModel()
        let a = UUID()
        let b = UUID()
        model.apply(status(a, name: "A"))
        model.apply(status(b, parent: a, name: "B"))
        model.apply(status(UUID(), parent: b, name: "B-child"))
        model.apply(status(UUID(), parent: a, name: "C"))

        let byName = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.item.name, $0) })
        #expect(byName["B"]?.isLastSibling == false)
        #expect(byName["C"]?.isLastSibling == true)
        // Depth-1 rows draw only their own trunk — the root contributes no column.
        #expect(byName["B"]?.ancestorLines.isEmpty == true)
        // B-child is depth 2, so it draws one ancestor column: A's. A still has C to come, so a line
        // passes through that column on its way down to C.
        #expect(byName["B-child"]?.ancestorLines.count == 1)
        #expect(byName["B-child"]?.ancestorLines.first??.isCompleted == false)
    }

    @Test("A pass-through line carries the state of the sibling it leads to")
    func passThroughLinesCarryDestinationState() {
        // The line crossing B-child's row is heading down to C, so it is tinted like C — otherwise a
        // finished sibling would show a green stub with a grey line running up to it.
        let model = RTSNodeTreeModel()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        model.apply(status(a, name: "A"))
        model.apply(status(b, parent: a, name: "B"))
        model.apply(status(UUID(), parent: b, name: "B-child"))
        model.apply(status(c, parent: a, name: "C"))
        model.apply(status(c, parent: a, name: "C", state: .completed))

        let bChild = model.rows.first { $0.item.name == "B-child" }
        #expect(bChild?.ancestorLines.first??.isCompleted == true)
    }
}
