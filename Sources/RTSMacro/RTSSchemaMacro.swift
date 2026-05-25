//
//  RTSSchemaMacro.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-25.
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Generates `RTSSchemaConvertible` conformance for the attached struct.
public struct RTSSchemaMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo decl: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = decl.as(StructDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@RTSSchema can only be applied to structs")
        }

        let typeName = structDecl.name.text

        // Collect stored, non-static, non-computed properties with their type annotations
        let props: [(name: String, typeNode: TypeSyntax, isOptional: Bool)] = decl.memberBlock.members.compactMap { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return nil }
            let isStatic = varDecl.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            guard !isStatic,
                  let binding = varDecl.bindings.first,
                  binding.accessorBlock == nil,
                  let id = binding.pattern.as(IdentifierPatternSyntax.self),
                  let typeAnnotation = binding.typeAnnotation else { return nil }

            let rawType = typeAnnotation.type.trimmed
            // Unwrap Optional<T> or T?
            if let optType = rawType.as(OptionalTypeSyntax.self) {
                return (id.identifier.text, optType.wrappedType.trimmed, true)
            }
            return (id.identifier.text, rawType, false)
        }

        let propertyLines = props.map { prop in
            schemaExpression(name: prop.name, typeNode: prop.typeNode, isOptional: prop.isOptional)
        }.joined(separator: ",\n            ")

        let extensionSource = """
        extension \(typeName): RTSSchemaConvertible {
            static var rtsSchema: RTSOutputSchema {
                RTSOutputSchema(name: "\(typeName)", type: .object(name: "\(typeName)", properties: [
                    \(propertyLines)
                ]))
            }
        }
        """

        let extensionDecl = try ExtensionDeclSyntax("\(raw: extensionSource)")
        return [extensionDecl]
    }

    // Produces the RTSOutputSchema(...) literal for a single property.
    private static func schemaExpression(name: String, typeNode: TypeSyntax, isOptional: Bool) -> String {
        let schemaType = schemaTypeExpression(for: typeNode)
        if isOptional {
            return "RTSOutputSchema(name: \"\(name)\", type: \(schemaType), isOptional: true)"
        }
        return "RTSOutputSchema(name: \"\(name)\", type: \(schemaType))"
    }

    // Maps a Swift TypeSyntax to an RTSOutputSchema.SchemaType expression string.
    private static func schemaTypeExpression(for typeNode: TypeSyntax) -> String {
        // Unwrap optional wrapper if present (e.g. called recursively from array element)
        if let optType = typeNode.as(OptionalTypeSyntax.self) {
            return schemaTypeExpression(for: optType.wrappedType.trimmed)
        }

        // Array type: [Element]
        if let arrayType = typeNode.as(ArrayTypeSyntax.self) {
            let elementExpr = schemaTypeExpression(for: arrayType.element.trimmed)
            return ".array(of: \(elementExpr))"
        }

        // Named type: String, Double, Bool, or custom RTSSchemaConvertible
        if let idType = typeNode.as(IdentifierTypeSyntax.self) {
            switch idType.name.text {
            case "String":           return ".string"
            case "Double", "Float", "Int", "Int32", "Int64": return ".number"
            case "Bool":             return ".boolean"
            default:
                // Assume custom type conforms to RTSSchemaConvertible
                return "\(idType.name.text).rtsSchema.type"
            }
        }

        // Fallback for any other type syntax
        return ".string"
    }
}
