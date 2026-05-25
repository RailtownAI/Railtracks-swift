import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Generates `encode(to:)` for the attached type, encoding each stored instance property
/// and emitting `null` for `nil` optionals instead of omitting the key.
public struct RTSEncodeNullsMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf decl: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let properties: [String] = decl.memberBlock.members.compactMap { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return nil }
            let isStatic = varDecl.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            guard !isStatic,
                  let binding = varDecl.bindings.first,
                  binding.accessorBlock == nil,
                  let id = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
            return id.identifier.text
        }

        let encodeLines = properties
            .map { "try container.encode(\($0), forKey: .\($0))" }
            .joined(separator: "\n")

        let accessLevel = decl.modifiers.first(where: {
            [.keyword(.public), .keyword(.package), .keyword(.internal), .keyword(.fileprivate), .keyword(.private), .keyword(.open)]
                .contains($0.name.tokenKind)
        })?.name.text

        let accessPrefix = accessLevel.map { "\($0) " } ?? ""
        let encodeFunc = """
         \(accessPrefix)func encode(to encoder: Encoder) throws {
             var container = encoder.container(keyedBy: CodingKeys.self)
             \(encodeLines)
         }
         """

        return [DeclSyntax(stringLiteral: encodeFunc)]
    }
}
