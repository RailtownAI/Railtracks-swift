//
//  RTSSchemaConvertible.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-25.
//

import Foundation

/// Conforming types can describe their shape as an `RTSOutputSchema`.
///
/// Apply `@RTSSchema` to a struct for automatic synthesis.
public protocol RTSSchemaConvertible {
    static var rtsSchema: RTSOutputSchema { get }
}

public extension RTSSchemaConvertible where Self: Decodable {
    /// Decodes the agent's JSON result into this type.
    ///
    /// ```swift
    /// let output = try await RTSFlow.run(agent: agent, prompt: "...", gateway: gateway)
    /// let result = try JobDescription.decode(from: output)
    /// ```
    static func decode(from output: RTSOutput, key: String = "result") throws -> Self {
        guard case .string(let json) = output[key] else {
            throw RTSError.missingInput("No string result in output for key '\(key)'")
        }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}
