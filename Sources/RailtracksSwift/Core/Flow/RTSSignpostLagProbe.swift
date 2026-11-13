//
//  RTSSignpostLagProbe.swift
//  RailtracksSwift
//
//  THROWAWAY (#70 step 1, not to be committed). Measures how late an interval begun and ended from
//  the internal event stream would be stamped, against the timestamps the events carry. See
//  docs/signposts-from-events.md, "Interval timing".
//

import Combine
import Foundation
import os.signpost
import Synchronization

/// One node's interval, as a signpost writer on the internal stream would have stamped it.
struct RTSSignpostLagSample: Sendable {
    let name: String
    let nodeType: RTSFlowNodeType
    /// Writer time at `begin` minus the executing signal's timestamp.
    let beginLag: TimeInterval
    /// Writer time at `end` minus `node.destruction`'s timestamp.
    let endLag: TimeInterval
    /// `node.destruction`'s timestamp minus the executing signal's: what `invokeCore` would stamp.
    let realDuration: TimeInterval

    /// The stamped duration minus the real one.
    var durationError: TimeInterval {
        endLag - beginLag
    }
}

/// Subscribes to the internal stream where the signpost writer would, stamps the delivery time of
/// each node's executing signal and destruction, and opens and closes a real `os_signpost` interval
/// at those points, so the cost of the writer's own calls is in the measurement and the bars can be
/// compared with `NodeRun`'s in Instruments.
final class RTSSignpostLagProbe: Sendable {
    private struct Node {
        let name: String
        let nodeType: RTSFlowNodeType
        var signalTimestamp: Date?
        var beginLag: TimeInterval?
        var intervalState: OSSignpostIntervalState?
    }

    private struct State {
        var nodes: [String: Node] = [:]
        var rootNodeIDs: Set<String> = []
        var runSamples: [UUID: [RTSSignpostLagSample]] = [:]
        var allSamples: [RTSSignpostLagSample] = []
    }

    private static let signposter = OSSignposter(subsystem: "ai.railtown.railtracks.probe", category: "Lag")

    private let state = Mutex(State())

    var samples: [RTSSignpostLagSample] {
        state.withLock { $0.allSamples }
    }

    func subscribe(to publisher: AnyPublisher<RTSObservedEvent, Never>) -> AnyCancellable {
        publisher.sink { [self] observed in
            receive(observed, at: Date())
        }
    }

    private func receive(_ observed: RTSObservedEvent, at deliveredAt: Date) {
        switch observed.event {
        case .nodeExecuting(let signal):
            begin(signal, at: deliveredAt)
        case .observability(let event):
            switch event {
            case let creation as RTSNodeCreationEvent:
                state.withLock { state in
                    state.nodes[creation.nodeID] = Node(name: creation.name, nodeType: creation.nodeType)
                }
            case let invocation as RTSNodeInvocationEvent:
                guard case .node(let nodeID) = invocation.parent,
                      case .node(nil) = invocation.spatialParent else {
                    return
                }
                state.withLock { state in
                    _ = state.rootNodeIDs.insert(nodeID)
                }
            case let destruction as RTSNodeDestructionEvent:
                end(destruction, at: deliveredAt, runScope: observed.runScope)
            default:
                break
            }
        }
    }

    private func begin(_ signal: RTSNodeExecutingSignal, at deliveredAt: Date) {
        let nodeID = signal.nodeID.uuidString
        let intervalState = Self.signposter.beginInterval("NodeRunProbe", id: Self.signposter.makeSignpostID())
        state.withLock { state in
            state.nodes[nodeID]?.signalTimestamp = signal.timestamp
            state.nodes[nodeID]?.beginLag = deliveredAt.timeIntervalSince(signal.timestamp)
            state.nodes[nodeID]?.intervalState = intervalState
        }
    }

    private func end(_ destruction: RTSNodeDestructionEvent, at deliveredAt: Date, runScope: UUID?) {
        guard case .node(let nodeID) = destruction.parent else {
            return
        }
        let finished = state.withLock { state -> (Node, Bool)? in
            guard let node = state.nodes.removeValue(forKey: nodeID) else {
                return nil
            }
            return (node, state.rootNodeIDs.remove(nodeID) != nil)
        }
        guard let (node, isRoot) = finished,
              let signalTimestamp = node.signalTimestamp,
              let beginLag = node.beginLag,
              let intervalState = node.intervalState else {
            print("⏱️ lag-probe: destruction with no begin for \(nodeID)")
            return
        }
        Self.signposter.endInterval("NodeRunProbe", intervalState)
        let sample = RTSSignpostLagSample(
            name: node.name,
            nodeType: node.nodeType,
            beginLag: beginLag,
            endLag: deliveredAt.timeIntervalSince(destruction.timestamp),
            realDuration: destruction.timestamp.timeIntervalSince(signalTimestamp)
        )
        let runKey = runScope ?? UUID()
        let runSamples = state.withLock { state -> [RTSSignpostLagSample]? in
            state.allSamples.append(sample)
            state.runSamples[runKey, default: []].append(sample)
            return isRoot ? state.runSamples.removeValue(forKey: runKey) : nil
        }
        if let runSamples {
            print(Self.summary(of: runSamples, title: "run, root \(node.name)"))
        }
    }

    // MARK: - Summary

    static func summary(of samples: [RTSSignpostLagSample], title: String) -> String {
        let beginLags = samples.map(\.beginLag)
        let durationErrors = samples.map { abs($0.durationError) }
        let tools = samples.filter { $0.nodeType != .agent && $0.realDuration > 0 }
        let relativeErrors = tools.map { abs($0.durationError) / $0.realDuration }
        return """
        ⏱️ lag-probe [\(title)] nodes=\(samples.count)
           offset (begin lag)  median=\(milliseconds(percentile(beginLags, 0.5))) \
        p99=\(milliseconds(percentile(beginLags, 0.99))) max=\(milliseconds(beginLags.max() ?? 0)) \
        spread=\(milliseconds((beginLags.max() ?? 0) - (beginLags.min() ?? 0)))
           |duration error|    median=\(milliseconds(percentile(durationErrors, 0.5))) \
        p99=\(milliseconds(percentile(durationErrors, 0.99))) max=\(milliseconds(durationErrors.max() ?? 0))
           tool/function relative error (\(tools.count))  median=\(percent(percentile(relativeErrors, 0.5))) \
        max=\(percent(relativeErrors.max() ?? 0))
        """
    }

    static func percentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[index]
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3fms", seconds * 1000)
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }
}
