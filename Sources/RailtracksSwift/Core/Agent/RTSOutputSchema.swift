//
//  RTSOutputSchema.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-25.
//

/// A schema node describing a named property and its type, nesting recursively.
///
/// Pass a root `.object` schema to `RTSAgent(outputSchema:)`:
///
/// ```swift
/// RTSOutputSchema(
///     name: "JobDescription",
///     type: .object(name: "JobDescription", properties: [
///         RTSOutputSchema(name: "title",        type: .string),
///         RTSOutputSchema(name: "salary",       type: .number, isOptional: true),
///         RTSOutputSchema(name: "tags",         type: .array(of: .string)),
///         RTSOutputSchema(name: "level",        type: .stringEnum(name: "Level", choices: ["junior", "mid", "senior"])),
///         RTSOutputSchema(name: "address",      type: .object(name: "Address", properties: [
///             RTSOutputSchema(name: "city",    type: .string),
///             RTSOutputSchema(name: "country", type: .string),
///         ])),
///     ])
/// )
/// ```
///
/// Or use `@RTSSchema` to derive the same schema from a struct automatically:
///
/// ```swift
/// @RTSSchema struct Address       { let city: String; let country: String }
/// @RTSSchema struct JobDescription {
///     let title:   String
///     let salary:  Double?
///     let tags:    [String]
///     let level:   String
///     let address: Address
/// }
///
/// let agent = RTSAgent(llmProvider: ..., outputSchema: JobDescription.rtsSchema)
/// ```
public struct RTSOutputSchema: Sendable {
    public let name: String
    public let type: SchemaType
    public let isOptional: Bool
    public let description: String?

    public init(
        name: String,
        type: SchemaType,
        isOptional: Bool = false,
        description: String? = nil
    ) {
        self.name = name
        self.type = type
        self.isOptional = isOptional
        self.description = description
    }

    public indirect enum SchemaType: Sendable {
        case string
        case number
        case boolean
        case array(of: SchemaType)
        case stringEnum(name: String, choices: [String])
        case object(name: String, properties: [RTSOutputSchema])
    }
}
