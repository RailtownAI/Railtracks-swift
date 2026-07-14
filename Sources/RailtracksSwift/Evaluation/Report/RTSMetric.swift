//
//  RTSMetric.swift
//  RailtracksSwift
//

import Foundation

// MARK: - Metric type

/// The `metric_type` discriminator as a String-backed, extensible value (like `Font`).
/// Known kinds are static constants; unknown values (added by Python or an app) are preserved
/// verbatim rather than rejected, so decoding never fails on a new type. Extend with more
/// constants via an extension on the application side.
public struct RTSMetricType: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let toolMetric: RTSMetricType = "ToolMetric"
    public static let llmMetric: RTSMetricType = "LLMMetric"
    public static let numerical: RTSMetricType = "Numerical"
    public static let categorical: RTSMetricType = "Categorical"
}

// MARK: - Numeric metric (ToolMetric / LLMMetric)

/// A numeric metric descriptor with optional bounds. Covers the `ToolMetric` and `LLMMetric`
/// variants (both numeric); `metricType` records which one.
@EncodeNulls
public struct RTSNumericalMetric: Codable, Sendable {
    public let name: String
    public let metricType: RTSMetricType
    public let identifier: String
    public let description: String?
    public let minValue: Double?
    public let maxValue: Double?

    public init(
        name: String,
        metricType: RTSMetricType,
        identifier: String,
        description: String? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil
    ) {
        self.name = name
        self.metricType = metricType
        self.identifier = identifier
        self.description = description
        self.minValue = minValue
        self.maxValue = maxValue
    }

    enum CodingKeys: String, CodingKey {
        case name
        case metricType = "metric_type"
        case identifier, description
        case minValue = "min_value"
        case maxValue = "max_value"
    }
}

public extension RTSNumericalMetric {
    /// Convenience initializer that derives a deterministic `identifier` from the metric's config,
    /// so two metrics with the same config share an id (and dedupe in `metrics_map`).
    init(
        name: String,
        metricType: RTSMetricType,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        description: String? = nil
    ) {
        let material = [
            metricType.rawValue,
            "name=\(name)",
            "min=\(minValue.map { String($0) } ?? "nil")",
            "max=\(maxValue.map { String($0) } ?? "nil")",
            "desc=\(description ?? "nil")",
        ].joined(separator: "|")
        self.init(
            name: name,
            metricType: metricType,
            identifier: RailtracksSwift.equalityHash(material),
            description: description,
            minValue: minValue,
            maxValue: maxValue
        )
    }
}

// MARK: - Categorical metric

/// A categorical metric descriptor — a fixed set of allowed labels (`categories`).
@EncodeNulls
public struct RTSCategoricalMetric: Codable, Sendable {
    public let name: String
    public let metricType: RTSMetricType
    public let identifier: String
    public let description: String?
    public let categories: [String]

    public init(
        name: String,
        identifier: String,
        description: String? = nil,
        categories: [String],
        metricType: RTSMetricType = .categorical
    ) {
        self.name = name
        self.metricType = metricType
        self.identifier = identifier
        self.description = description
        self.categories = categories
    }

    enum CodingKeys: String, CodingKey {
        case name
        case metricType = "metric_type"
        case identifier, description, categories
    }
}

// MARK: - Polymorphic metric

/// A metric definition — a declarative *descriptor* (label + bounds/categories), not a scoring
/// function. Serialized polymorphically on the `metric_type` discriminator: numeric
/// (`ToolMetric`/`LLMMetric`) → `RTSNumericalMetric`, `Categorical` → `RTSCategoricalMetric`.
public enum RTSMetric: Codable, Sendable {
    case numerical(RTSNumericalMetric)
    case categorical(RTSCategoricalMetric)

    private enum TypeKey: String, CodingKey { case metricType = "metric_type" }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(RTSMetricType.self, forKey: .metricType)
        if type == .categorical {
            self = .categorical(try RTSCategoricalMetric(from: decoder))
        } else {                                   // ToolMetric | LLMMetric | Numerical | unknown
            self = .numerical(try RTSNumericalMetric(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .numerical(let metric):   try metric.encode(to: encoder)
        case .categorical(let metric): try metric.encode(to: encoder)
        }
    }

    /// The metric's identifier, regardless of variant.
    public var identifier: String {
        switch self {
        case .numerical(let metric):   return metric.identifier
        case .categorical(let metric): return metric.identifier
        }
    }
}
