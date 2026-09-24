//
//  RTSAppleAIToolNode.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-27.
//

import Foundation
import FoundationModels

/// A tool that works with both the RailtracksSwift pipeline and Apple's on-device LLM.
///
/// Conform to this to make a tool available when using `RTSAgent(llmProvider: .appleAI)`.
///
/// ## Defaults provided by this protocol
///
/// - `name` / `description` forward to `toolName` / `toolDescription` — define each once. `name` is
///   sanitized on the way out (`Photo Search` → `Photo_Search`) so the model sees one identifier for
///   this tool whichever provider is behind it; `toolName` keeps the authored spelling for tracing.
/// - `parameterSchema` is derived automatically from `Arguments.generationSchema` (requires
///   `@Generable Arguments`), so the `@Guide` descriptions you write for AppleAI also populate
///   the OpenAI tool schema with no extra work.
/// - `call(arguments:)` is bridged to `callableRoutine` automatically when
///   `Arguments: Encodable` and `Output == String`, so a single `callableRoutine`
///   implementation runs for both providers.
///
/// ## Minimum conformance
///
/// ```swift
/// struct AdditionTool: RTSAppleAIToolNode {
///     var toolName = "addition"
///     var toolDescription = "Adds two numbers"
///
///     var callableRoutine: RTSClosure { RTSClosure { input in ... } }
///
///     @Generable struct Arguments: Encodable {
///         @Guide(description: "First operand") var a: Double
///         @Guide(description: "Second operand") var b: Double
///     }
///     typealias Output = String
///     // parameterSchema and call(arguments:) are provided automatically
/// }
/// ```
///
/// Note: tool invocations via `LanguageModelSession` pass through `RTSAppleAIToolBridge` and
/// `RTSNodeInvoker`, so they appear in the flow graph trace the same way OpenAI tools do.
@available(macOS 26, iOS 26, *)
public protocol RTSAppleAIToolNode: RTSToolNode, Tool {
    /// Returns a bridge that routes `call(arguments:)` through `RTSNodeInvoker` for flow graph
    /// tracking. The default implementation in `RTSAppleAIToolBridge.swift` handles conformers
    /// where `Arguments: Encodable, Output == String`; returns `nil` otherwise.
    func makeAppleAIBridge(invoker: RTSNodeInvoker, createdBy: any RTSAgentNode) -> (any Tool)?
}

@available(macOS 26, iOS 26, *)
public extension RTSAppleAIToolNode {
    /// The identifier FoundationModels sees. Sanitized for the same reason the cloud bridges
    /// sanitize: FoundationModels accepts any name, but a tool must not present a different name to
    /// the model depending on which provider is behind it.
    ///
    /// This matters on the path where `makeAppleAIBridge` returns `nil` and the conformer is handed
    /// to `LanguageModelSession` directly — there is no bridge in between to sanitize on its behalf,
    /// so it has to happen here. The authored name is untouched on `toolName` and `name()`, which is
    /// what the flow graph trace records.
    var name: String { RTSProviderSafeName.sanitized(toolName) }
    var description: String { toolDescription }
    func makeAppleAIBridge(invoker: RTSNodeInvoker, createdBy: any RTSAgentNode) -> (any Tool)? { nil }
}

@available(macOS 26, iOS 26, *)
public extension RTSAppleAIToolNode where Arguments: Generable {
    /// Derives `parameterSchema` from the `@Generable Arguments` struct through `GenerationSchema`'s
    /// public `Codable` form — a JSON Schema — so `@Guide` descriptions double as OpenAI parameter docs.
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: Self.extractParameters(from: Arguments.generationSchema))
    }

    //TODO: return nil if failure instead of empty array?
    /// Reads the top-level `properties` of the encoded JSON Schema, in declaration order (`x-order`).
    private static func extractParameters(from schema: GenerationSchema) -> [RTSToolSchema.Parameter] {
        let jsonSchema: [String: Any]
        do {
            let encoded = try JSONEncoder().encode(schema)
            jsonSchema = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        } catch {
            log.error("☠️ unable to encode GenerationSchema for tool parameters: \(error)")
            return []
        }
        guard let properties = jsonSchema["properties"] as? [String: [String: Any]] else {
            log.error("☠️ GenerationSchema JSON has no object `properties`: \(jsonSchema)")
            return []
        }
        let order = jsonSchema["x-order"] as? [String] ?? properties.keys.sorted()
        return order.compactMap { name in
            guard let property = properties[name] else {
                return nil
            }
            return RTSToolSchema.Parameter(
                name: name,
                description: property["description"] as? String ?? "",
                type: valueType(of: property)
            )
        }
    }

    /// Maps a JSON Schema property to `RTSValueType`. Anything without a direct equivalent — objects,
    /// references, arrays of those — is `.string`, as before.
    private static func valueType(of property: [String: Any]) -> RTSValueType {
        switch property["type"] as? String {
        case "string":
            return .string
        case "number", "integer":
            return .number
        case "boolean":
            return .bool
        case "array":
            let items = property["items"] as? [String: Any] ?? [:]
            switch items["type"] as? String {
            case "string":
                return .array(.string)
            case "number", "integer":
                return .array(.number)
            case "boolean":
                return .array(.bool)
            default:
                return .string
            }
        default:
            return .string
        }
    }
}

@available(macOS 26, iOS 26, *)
public extension RTSAppleAIToolNode where Arguments: Encodable & Generable, Output == String {
    /// Bridges FoundationModels tool invocation to the existing `callableRoutine`.
    /// Requires `Arguments: Encodable & Generable` (add `Encodable` alongside `@Generable`) and `Output == String`.
    func call(arguments: Arguments) async throws -> String {
        let data = try JSONEncoder().encode(arguments)
        let input = try JSONDecoder().decode(RTSInput.self, from: data)
        let output = try await callableRoutine.closure(input)
        let outputData = try JSONEncoder().encode(output)
        return String(data: outputData, encoding: .utf8) ?? "{}"
    }
}
