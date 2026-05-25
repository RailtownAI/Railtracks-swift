/// Synthesizes `RTSSchemaConvertible` conformance for a struct.
///
/// Apply to any struct whose stored properties are all `RTSSchemaConvertible`
/// primitive types (`String`, `Double`, `Bool`), arrays thereof, or other
/// `@RTSSchema`-annotated structs. The macro generates an `rtsSchema` static
/// property describing the struct as an `.object` schema.
///
/// ```swift
/// @RTSSchema
/// struct JobHeader {
///     let title: String
///     let company: String
///     let location: String
/// }
/// // Equivalent to:
/// // extension JobHeader: RTSSchemaConvertible {
/// //     static var rtsSchema: RTSOutputSchema {
/// //         RTSOutputSchema(name: "JobHeader", type: .object(name: "JobHeader", properties: [
/// //             RTSOutputSchema(name: "title",    type: .string),
/// //             RTSOutputSchema(name: "company",  type: .string),
/// //             RTSOutputSchema(name: "location", type: .string),
/// //         ]))
/// //     }
/// // }
/// ```
@attached(extension, conformances: RTSSchemaConvertible, names: named(rtsSchema))
public macro RTSSchema() = #externalMacro(module: "RTSMacro", type: "RTSSchemaMacro")
