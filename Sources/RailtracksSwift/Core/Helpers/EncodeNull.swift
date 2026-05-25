/// Generates an `encode(to:)` implementation that encodes all stored properties,
/// encoding `nil` optionals as JSON `null` rather than omitting the key.
@attached(member, names: named(encode))
public macro EncodeNulls() = #externalMacro(
    module: "EncodeNullMacro",
    type: "EncodeNullsMacro"
)
