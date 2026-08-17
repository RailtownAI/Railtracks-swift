//
//  RTSNodeTreeView.swift
//  RailtracksSwiftUI
//

import SwiftUI
import RailtracksSwift

/// A live call tree of a flow's node invocations.
///
/// ```swift
/// RTSNodeTreeView(flow: flow)
/// ```
///
/// The view only observes; the app still calls `flow.run(...)`. Rows appear as nodes are invoked and
/// nest under whichever invocation triggered them, so a node invoked twice produces two rows.
public struct RTSNodeTreeView: View {
    @State private var model: RTSNodeTreeModel
    /// Cleared once the user scrolls, so the view stops yanking the viewport away from them.
    @State private var followsTail = true
    @State private var scrollPosition = ScrollPosition(edge: .top)

    public init(flow: RTSFlow) {
        _model = State(initialValue: RTSNodeTreeModel(flow: flow))
    }

    /// For previews and tests, where statuses are fed to the model by hand.
    public init(model: RTSNodeTreeModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    if row.startsNewRun {
                        Divider()
                            .padding(.vertical, 8)
                    }
                    RTSNodeTreeRowView(row: row) {
                        model.toggleCollapse(row.id)
                    }
                    .id(row.id)
                }
                // Anchor for tail-following: scrolling to the bottom of the content rather than to
                // the newest row is what keeps this from bouncing between distant nodes when
                // parallel branches grow at once.
                Color.clear
                    .frame(height: 1)
                    .id(Self.tailAnchor)
            }
            .padding(12)
        }
        .scrollPosition($scrollPosition)
        .onScrollPhaseChange { _, phase in
            // Any hands-on scroll takes over; returning to the bottom hands control back.
            switch phase {
            case .interacting:
                followsTail = false
            case .idle:
                if scrollPosition.isPositionedByUser == false {
                    followsTail = true
                }
            default:
                break
            }
        }
        .onChange(of: model.rows.count) {
            guard followsTail else {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private static let tailAnchor = "rts-node-tree-tail"
}

/// One row: status circle, node-type glyph, name — with the connector lines for its depth.
struct RTSNodeTreeRowView: View {
    let row: RTSNodeTreeRow
    let onToggleCollapse: () -> Void

    private static let indent: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            connectors
            RTSNodeStatusIcon(state: row.item.state)
            Image(systemName: row.item.nodeType.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(row.item.nodeType.accessibilityName)
            Text(row.item.name)
                .font(.callout)
            if row.hasChildren {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.hasChildren else {
                return
            }
            onToggleCollapse()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.item.nodeType.accessibilityName) \(row.item.name), \(row.item.state.accessibilityDescription)")
    }

    /// Vertical lines for ancestor levels, then this row's own elbow.
    private var connectors: some View {
        HStack(spacing: 0) {
            ForEach(Array(row.ancestorHasMoreSiblings.enumerated()), id: \.offset) { _, hasMore in
                Rectangle()
                    .fill(hasMore ? Color.secondary.opacity(0.35) : .clear)
                    .frame(width: 1)
                    .frame(width: Self.indent, alignment: .leading)
            }
            if row.depth > 0 {
                RTSTreeElbow(isLastSibling: row.isLastSibling)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    .frame(width: Self.indent)
            }
        }
        .frame(height: 26)
    }
}

/// The `├`/`└` joint linking a row to its parent's vertical line.
struct RTSTreeElbow: Shape {
    let isLastSibling: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // A last child's line stops at the elbow; otherwise it continues to the next sibling.
        path.addLine(to: CGPoint(x: rect.minX, y: isLastSibling ? midY : rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        return path
    }
}

/// Status circle: colour carries state, and only `.executing` spins.
struct RTSNodeStatusIcon: View {
    let state: RTSNodeStatus.State

    private static let diameter: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .fill(state.tint)
                .frame(width: Self.diameter, height: Self.diameter)
            if case .executing = state {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
        .frame(width: 18, height: 18)
    }
}

extension RTSNodeStatus.State {
    /// Semantic colours so both appearances stay legible; state owns colour outright, which is why
    /// node type is drawn as a separate glyph rather than tinted.
    var tint: Color {
        switch self {
        case .queued:
            return .secondary.opacity(0.4)
        case .executing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .queued:
            return "queued"
        case .executing:
            return "running"
        case .completed:
            return "completed"
        case .failed(let message):
            return "failed: \(message)"
        }
    }
}

extension RTSFlowNodeType {
    var symbolName: String {
        switch self {
        case .agent:
            return "brain"
        case .tool:
            return "wrench.and.screwdriver"
        case .function:
            return "function"
        }
    }

    var accessibilityName: String {
        switch self {
        case .agent:
            return "Agent"
        case .tool:
            return "Tool"
        case .function:
            return "Function"
        }
    }
}
