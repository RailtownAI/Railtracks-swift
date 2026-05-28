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
/// - `name` / `description` forward to `toolName` / `toolDescription` — define each once.
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
public protocol RTSAppleAIToolNode: RTSToolNode, Tool {
    /// Returns a bridge that routes `call(arguments:)` through `RTSNodeInvoker` for flow graph
    /// tracking. The default implementation in `RTSAppleAIToolBridge.swift` handles conformers
    /// where `Arguments: Encodable, Output == String`; returns `nil` otherwise.
    func makeAppleAIBridge(invoker: RTSNodeInvoker, createdBy: any RTSAgentNode) -> (any Tool)?
}

public extension RTSAppleAIToolNode {
    var name: String { toolName }
    var description: String { toolDescription }
    func makeAppleAIBridge(invoker: RTSNodeInvoker, createdBy: any RTSAgentNode) -> (any Tool)? { nil }
}

public extension RTSAppleAIToolNode where Arguments: Generable {
    /// Derives `parameterSchema` from the `@Generable Arguments` struct by reflecting
    /// over `GenerationSchema`, so `@Guide` descriptions double as OpenAI parameter docs.
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: Self.extractParameters(from: Arguments.generationSchema))
    }

    //TODO: return nil if failure instead of empty array?
    /// This `extractParameters(from:)` function heavily depend on existing Apple structure stays consistent
    private static func extractParameters(from schema: GenerationSchema) -> [RTSToolSchema.Parameter] {
        guard
            let kindValue      = Mirror(reflecting: schema).children.first(where: { $0.label == "kind" })?.value,
            let structureValue = Mirror(reflecting: kindValue).children.first(where: { $0.label == "structure" })?.value,
            let propertiesAny  = Mirror(reflecting: structureValue).children.first(where: { $0.label == "properties" })?.value,
            let propertiesArr  = propertiesAny as? [Any]
        else {
            log.error("☠️ unable to extract parameters from schema. Mirror reflection is broken.")
            return []
        }

        return propertiesArr.compactMap { prop in
            let m = Mirror(reflecting: prop)
            guard
                let name    = m.children.first(where: { $0.label == "name" })?.value as? String,
                let typeVal = m.children.first(where: { $0.label == "type" })?.value
            else { return nil }
            let description = (m.children.first(where: { $0.label == "description" })?.value)
                .flatMap { $0 as? String } ?? ""
            let valueType: RTSValueType
            switch "\(typeVal)" {
            case "String":                  valueType = .string
            case "Double", "Int", "Float":  valueType = .number
            case "Bool":                    valueType = .bool
            default:                        valueType = .string
            }
            return RTSToolSchema.Parameter(name: name, description: description, type: valueType)
        }
    }
}

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
