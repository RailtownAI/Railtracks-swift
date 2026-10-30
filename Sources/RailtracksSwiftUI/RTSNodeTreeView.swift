//
//  RTSNodeTreeView.swift
//  RailtracksSwiftUI
//

import SwiftUI
import RailtracksSwift

/// A live call tree of a flow's node invocations.
///
/// The parent owns both halves — the view model alongside its own, the view alongside its own:
///
/// ```swift
/// @Observable final class MyViewModel {
///     @MainActor let nodeTree = RTSNodeTreeViewModel()
///
///     func run() {
///         let flow = RTSFlow(title: "My Flow")
///         nodeTree.attach(to: flow)
///         // …flow.run(…)
///     }
/// }
///
/// RTSNodeTreeView(viewModel: myViewModel.nodeTree)
/// ```
///
/// Attaching at flow creation rather than passing the flow to the view is deliberate: apps typically
/// build a fresh `RTSFlow` per run, often inside a `Task`, where it never reaches view-visible state
/// for SwiftUI to notice. `attach(to:)` also begins observing at the moment of creation rather than
/// at the next render pass, so nothing is missed.
///
/// The view only observes; the app still calls `flow.run(...)`. Rows appear as nodes are invoked and
/// nest under whichever invocation triggered them, so a node invoked twice produces two rows.
public struct RTSNodeTreeView: View {
    /// A plain `let`: the caller owns the view model's lifetime, and the view must pick up a
    /// different one if handed one. `@State` would latch the first value and ignore the rest.
    private let viewModel: RTSNodeTreeViewModel

    /// Follows new rows until the reader scrolls away, and resumes once they return to the bottom.
    @State private var followsTail = true
    @State private var scrollPosition = ScrollPosition(edge: .top)

    public init(viewModel: RTSNodeTreeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.rows) { row in
                    if row.startsNewRun {
                        Divider()
                            .padding(.vertical, 8)
                    }
                    RTSNodeTreeRowView(row: row) {
                        viewModel.toggleCollapse(row.id)
                    }
                    .id(row.id)
                }
            }
            .padding(12)
        }
        .scrollPosition($scrollPosition)
        // Derived from where the viewport actually sits, not from whether a scroll ever happened:
        // `ScrollPosition.isPositionedByUser` latches true after the first touch, which would leave
        // auto-follow dead for the rest of the view's life after a single nudge.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distanceFromBottom = geometry.contentSize.height
                - geometry.contentOffset.y
                - geometry.containerSize.height
            return distanceFromBottom <= Self.tailThreshold
        } action: { _, isAtBottom in
            followsTail = isAtBottom
        }
        // Scrolls to the bottom of the content rather than to the newest row: new rows can be
        // inserted mid-tree, and chasing them would bounce the viewport between distant branches.
        // The content bottom only ever moves downward, so following it cannot oscillate.
        .onChange(of: viewModel.rows.count) {
            guard followsTail else {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    /// Slack for "at the bottom", so sub-pixel rounding or a hair of overscroll does not read as the
    /// reader having deliberately scrolled away.
    private static let tailThreshold: CGFloat = 8
}

/// One row: status circle, node-type glyph, name — with the connector lines for its depth.
struct RTSNodeTreeRowView: View {
    let row: RTSNodeTreeRow
    let onToggleCollapse: () -> Void

    /// Width of one tree level. The status circle occupies a column of exactly this width too, so a
    /// child's elbow lands on its parent's circle centre rather than beside it.
    static let indent: CGFloat = 24
    static let rowHeight: CGFloat = 26

    var body: some View {
        // Zero spacing through the connector and circle columns: any gap inserted here would offset
        // every circle from the column grid its children's connectors are drawn against. Spacing to
        // the right of the circle is added per-view instead.
        HStack(spacing: 0) {
            connectors
            RTSNodeStatusIcon(
                state: row.item.state,
                showsChildStem: row.hasChildren && !row.isCollapsed
            )
            Image(systemName: row.item.nodeType.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .accessibilityLabel(row.item.nodeType.accessibilityName)
            Text(row.item.name)
                .font(.callout)
                .padding(.leading, 6)
            if row.hasChildren {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
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

    /// Ancestor lines plus this row's own branch, drawn in one coordinate space.
    ///
    /// Two overlaid shapes so they can be tinted separately: everything belonging to *this* node's
    /// branch takes its state colour, while lines merely passing through on their way to an
    /// ancestor's later sibling stay neutral.
    private var connectors: some View {
        ZStack(alignment: .leading) {
            // Drawn as individual views rather than one stroked path because each carries the tint of
            // whichever node its line is heading toward, so tints differ within a single row.
            ForEach(Array(row.ancestorLines.enumerated()), id: \.offset) { level, destination in
                if let destination {
                    Rectangle()
                        .fill(destination.lineTint)
                        .frame(width: Self.lineWidth, height: Self.rowHeight)
                        .offset(x: CGFloat(level) * Self.indent + (Self.indent - Self.lineWidth) / 2)
                }
            }

            RTSTreeBranch(
                depth: row.depth,
                isLastSibling: row.isLastSibling,
                indent: Self.indent
            )
            .stroke(row.item.state.lineTint, lineWidth: Self.lineWidth)
        }
        .frame(width: CGFloat(row.depth) * Self.indent, height: Self.rowHeight)
    }

    /// Matches the connector weight used by the demo's step view, so the two read as one language.
    static let lineWidth: CGFloat = 2
}

/// The trunk down from this node's parent and the arm across to its circle, drawn in the node's state
/// colour so the whole branch turns green as the node completes.
///
/// The trunk sits at `(depth - 1) * indent + indent / 2` — the same x as the parent's status circle,
/// since a circle occupies a column of `indent` too.
struct RTSTreeBranch: Shape {
    let depth: Int
    let isLastSibling: Bool
    let indent: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard depth > 0 else {
            return path
        }
        let trunkX = CGFloat(depth - 1) * indent + indent / 2
        path.move(to: CGPoint(x: trunkX, y: rect.minY))
        // Stops at this row's centre when it is the last child; otherwise carries on to the row edge,
        // where the next sibling's own trunk picks it up.
        path.addLine(to: CGPoint(x: trunkX, y: isLastSibling ? rect.midY : rect.maxY))
        path.move(to: CGPoint(x: trunkX, y: rect.midY))
        // Overshoots the prefix by half an indent to reach the centre of this row's circle, which is
        // laid out immediately to the right and drawn over the line's end.
        path.addLine(to: CGPoint(x: rect.maxX + indent / 2, y: rect.midY))
        return path
    }
}

/// Status circle: colour carries state, and only `.executing` spins.
struct RTSNodeStatusIcon: View {
    let state: RTSNodeStatus.State
    /// Draws the stem running from this circle down to the first child's row.
    var showsChildStem: Bool = false

    private static let diameter: CGFloat = 14

    var body: some View {
        ZStack {
            // Behind the circle, and owned by the circle rather than the row's connector prefix: the
            // root's prefix is zero-width, so a stem drawn there would never render for it.
            if showsChildStem {
                RTSTreeChildStem()
                    .stroke(state.lineTint, lineWidth: RTSNodeTreeRowView.lineWidth)
            }
            Circle()
                .fill(state.tint)
                .frame(width: Self.diameter, height: Self.diameter)
            if case .executing = state {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
        // A full indent-width column, so the circle's centre sits exactly where a child's connector
        // expects to find it, and the full row height so the stem reaches the next row.
        .frame(width: RTSNodeTreeRowView.indent, height: RTSNodeTreeRowView.rowHeight)
    }
}

/// The stem from a node's circle down to the top of its first child's row.
struct RTSTreeChildStem: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

extension RTSNodeStatus.State {
    /// Semantic colours so both appearances stay legible; state owns colour outright, which is why
    /// node type is drawn as a separate glyph rather than tinted.
    /// Connector colour: the state's tint at half strength, so lines read as structure and the
    /// circles stay the thing your eye lands on.
    var lineTint: Color {
        tint.opacity(0.5)
    }

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
        case .cancelled:
            return .orange
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
        case .cancelled:
            return "cancelled"
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
