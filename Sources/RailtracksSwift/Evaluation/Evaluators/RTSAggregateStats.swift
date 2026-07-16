//
//  RTSAggregateStats.swift
//  RailtracksSwift
//

import Foundation

// MARK: - Numeric statistics

/// Computes the numeric aggregate statistics carried by `RTSToolAggregate` /
/// `RTSLLMInferenceAggregate`. Matches the Python evaluator math exactly: population std (÷N),
/// even-N median = mean of the two middle values, mode = most frequent (ties broken by first
/// appearance). All fields are nil for an empty value set.
enum RTSAggregateStats {
    struct Numeric {
        let mean: Double?
        let minimum: Double?
        let maximum: Double?
        let median: Double?
        let std: Double?
        let mode: Double?
    }

    static func numeric(_ values: [Double]) -> Numeric {
        guard !values.isEmpty else {
            return Numeric(
                mean: nil,
                minimum: nil,
                maximum: nil,
                median: nil,
                std: nil,
                mode: nil
            )
        }

        let count = Double(values.count)
        let mean = values.reduce(0, +) / count

        let sorted = values.sorted()
        let n = sorted.count
        let median = n.isMultiple(of: 2)
            ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2
            : sorted[n / 2]

        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let std = variance.squareRoot()

        var counts: [Double: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        let maxCount = counts.values.max() ?? 0
        let mode = values.first { counts[$0] == maxCount }

        return Numeric(
            mean: mean,
            minimum: values.min(),
            maximum: values.max(),
            median: median,
            std: std,
            mode: mode
        )
    }
}

// MARK: - RTSValue numeric helper

extension RTSValue {
    /// The numeric payload if this value is a number, otherwise nil.
    var numberValue: Double? {
        if case .number(let number) = self {
            return number
        }
        return nil
    }
}

// MARK: - Forest node accessors

extension RTSAggregateNode {
    /// The node's identifier, regardless of shape.
    var identifier: String {
        switch self {
        case .tool(let result):               return result.identifier
        case .llm(let result):                return result.identifier
        case .base(let result):               return result.identifier
        case .toolAggregate(let node):        return node.identifier
        case .llmAggregate(let node):         return node.identifier
        case .categoricalAggregate(let node): return node.identifier
        }
    }

    /// Numeric values this node contributes to an ancestor: a leaf's own numeric value, or an
    /// aggregate's already-materialized `values`. Non-numeric leaves / categorical aggregates: none.
    var numericContribution: [Double] {
        switch self {
        case .tool(let result):        return result.value.numberValue.map { [$0] } ?? []
        case .llm(let result):         return result.value.numberValue.map { [$0] } ?? []
        case .base(let result):        return result.value.numberValue.map { [$0] } ?? []
        case .toolAggregate(let node): return node.values
        case .llmAggregate(let node):  return node.values
        case .categoricalAggregate:    return []
        }
    }
}

// MARK: - Forest builder

/// Mutable helper for assembling an `RTSAggregateForest` bottom-up: add leaves first, then
/// aggregate nodes (whose numeric stats are materialized from their descendants at add time).
struct RTSForestBuilder {
    private var nodes: [String: RTSAggregateNode] = [:]
    private var roots: [String] = []

    /// Insert a node (leaf or aggregate) into the flat node map.
    mutating func add(_ node: RTSAggregateNode) {
        nodes[node.identifier] = node
    }

    /// Mark a node id as a top-level forest root.
    mutating func addRoot(_ identifier: String) {
        roots.append(identifier)
    }

    /// All numeric values beneath the given child ids. Aggregates already carry their
    /// materialized `values`, so no deeper recursion is needed here.
    func numericValues(ofChildren children: [String]) -> [Double] {
        children.flatMap { nodes[$0]?.numericContribution ?? [] }
    }

    func build() -> RTSAggregateForest {
        RTSAggregateForest(roots: roots, nodes: nodes)
    }
}
