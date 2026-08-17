//
//  RTSNodeTreeModel.swift
//  RailtracksSwiftUI
//

import Foundation
import Combine
import RailtracksSwift

/// One invocation in the call tree.
///
/// Identity is per *invocation*, not per node instance — a tool called three times is three
/// `RTSNodeTreeItem`s with three ids, which is what lets repeat calls stack as separate rows.
@MainActor
public struct RTSNodeTreeItem: Identifiable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    public let name: String
    public let nodeType: RTSFlowNodeType
    public internal(set) var state: RTSNodeStatus.State
    /// Ids of invocations this one triggered, in the order they arrived.
    public internal(set) var childIDs: [UUID] = []
    /// Which run this belongs to, counting from zero. Used to draw a divider between runs.
    public let runIndex: Int
}

/// A row in the flattened, render-ready view of the tree.
public struct RTSNodeTreeRow: Identifiable, Sendable {
    public let id: UUID
    public let item: RTSNodeTreeItem
    public let depth: Int
    /// For each ancestor level, whether that ancestor has a later sibling — i.e. whether a vertical
    /// connector should be drawn in that column. Index 0 is the outermost level.
    public let ancestorHasMoreSiblings: [Bool]
    /// Whether this row is the last child of its parent, which turns its own elbow from `├` to `└`.
    public let isLastSibling: Bool
    public let hasChildren: Bool
    public let isCollapsed: Bool
    /// True for the first row of every run after the first, so the view can draw a separator.
    public let startsNewRun: Bool
}

/// Builds a live call tree from a flow's node status stream.
///
/// Subscribes on `init` and keeps accumulating, so a flow run more than once stacks its runs rather
/// than replacing them. The view only observes — the app still drives `flow.run(...)` itself.
@MainActor
@Observable
public final class RTSNodeTreeModel {
    /// Flattened depth-first, ready to render. Recomputed whenever the tree or collapse state changes.
    public private(set) var rows: [RTSNodeTreeRow] = []

    private var items: [UUID: RTSNodeTreeItem] = [:]
    /// Roots in arrival order — one per run, since only a run's root has no parent.
    private var rootIDs: [UUID] = []
    private var collapsedIDs: Set<UUID> = []
    private var cancellable: AnyCancellable?

    public init(flow: RTSFlow) {
        attach(to: flow)
    }

    /// A model with nothing attached — for previews and tests, or for a view that outlives the flows
    /// it observes and calls `attach(to:)` as each one is created.
    public init() {
    }

    /// Observes `flow`, replacing any previous subscription but **keeping** the accumulated tree.
    ///
    /// Apps that build a fresh `RTSFlow` per run (rather than re-running one instance) can call this
    /// each time and still get the run-over-run history: every flow contributes its own parentless
    /// root, which is what the divider keys off.
    public func attach(to flow: RTSFlow) {
        cancellable = flow.nodeStatusPublisher
            // Combine delivers on whichever task published; the tree feeds SwiftUI.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.apply(status)
            }
    }

    /// Drops every row and run recorded so far. The current subscription is left in place.
    public func reset() {
        items.removeAll()
        rootIDs.removeAll()
        collapsedIDs.removeAll()
        rows = []
    }

    public func toggleCollapse(_ id: UUID) {
        if collapsedIDs.contains(id) {
            collapsedIDs.remove(id)
        } else {
            collapsedIDs.insert(id)
        }
        rebuildRows()
    }

    public func isCollapsed(_ id: UUID) -> Bool {
        collapsedIDs.contains(id)
    }

    /// Applies one status event. Exposed for previews and tests; the flow subscription calls it.
    public func apply(_ status: RTSNodeStatus) {
        if var existing = items[status.nodeID] {
            existing.state = status.state
            items[status.nodeID] = existing
            rebuildRows()
            return
        }

        // A node with no parent is a run root: each run builds a fresh invoker, so its task-local
        // starts nil. That makes run boundaries derivable without any extra signal from the library.
        let parentID = status.parentNodeID
        let runIndex = parentID == nil
            ? rootIDs.count
            : (parentID.flatMap { items[$0]?.runIndex } ?? max(rootIDs.count - 1, 0))

        let item = RTSNodeTreeItem(
            id: status.nodeID,
            parentID: parentID,
            name: status.nodeName,
            nodeType: status.nodeType,
            state: status.state,
            runIndex: runIndex
        )
        items[status.nodeID] = item

        if let parentID, items[parentID] != nil {
            items[parentID]?.childIDs.append(status.nodeID)
        } else if parentID == nil {
            rootIDs.append(status.nodeID)
        } else {
            // Parent unknown: invocation-id propagation was lost upstream (the invoker logs an error
            // for this). Attach to the newest root so the node stays visible instead of vanishing —
            // a propagation bug should look wrong, not look like nothing happened.
            if let fallbackRoot = rootIDs.last {
                items[status.nodeID] = RTSNodeTreeItem(
                    id: status.nodeID,
                    parentID: fallbackRoot,
                    name: status.nodeName,
                    nodeType: status.nodeType,
                    state: status.state,
                    runIndex: items[fallbackRoot]?.runIndex ?? 0
                )
                items[fallbackRoot]?.childIDs.append(status.nodeID)
            } else {
                rootIDs.append(status.nodeID)
            }
        }
        rebuildRows()
    }

    private func rebuildRows() {
        var built: [RTSNodeTreeRow] = []
        for (index, rootID) in rootIDs.enumerated() {
            appendRows(
                for: rootID,
                depth: 0,
                ancestorHasMoreSiblings: [],
                isLastSibling: true,
                startsNewRun: index > 0,
                into: &built
            )
        }
        rows = built
    }

    private func appendRows(
        for id: UUID,
        depth: Int,
        ancestorHasMoreSiblings: [Bool],
        isLastSibling: Bool,
        startsNewRun: Bool,
        into built: inout [RTSNodeTreeRow]
    ) {
        guard let item = items[id] else {
            return
        }
        let collapsed = collapsedIDs.contains(id)
        built.append(
            RTSNodeTreeRow(
                id: id,
                item: item,
                depth: depth,
                ancestorHasMoreSiblings: ancestorHasMoreSiblings,
                isLastSibling: isLastSibling,
                hasChildren: !item.childIDs.isEmpty,
                isCollapsed: collapsed,
                startsNewRun: startsNewRun
            )
        )
        guard !collapsed else {
            return
        }
        // A row at depth d draws (d - 1) ancestor columns plus its own elbow, so the root contributes
        // no column at all — its children sit at depth 1 with an elbow and nothing to their left.
        // Below the root, this node's column keeps a vertical line only while it has siblings still
        // to come, so a descendant's line runs past it down to the next sibling.
        let childAncestors = depth == 0
            ? []
            : ancestorHasMoreSiblings + [!isLastSibling]
        for (index, childID) in item.childIDs.enumerated() {
            let childIsLast = index == item.childIDs.count - 1
            appendRows(
                for: childID,
                depth: depth + 1,
                ancestorHasMoreSiblings: childAncestors,
                isLastSibling: childIsLast,
                startsNewRun: false,
                into: &built
            )
        }
    }
}
