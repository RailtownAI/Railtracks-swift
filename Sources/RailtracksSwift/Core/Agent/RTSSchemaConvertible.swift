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
public protocol RTSSchemaConvertible: Codable, Sendable {
    static var rtsSchema: RTSOutputSchema { get }
}

public extension RTSSchemaConvertible {
    /// Decodes the agent's JSON result string into this type.
    ///
    /// ```swift
    /// let json = try await flow.run(agent: agent, prompt: "...", gateway: gateway)
    /// let result = try JobDescription.decode(from: json)
    /// ```
    static func decode(from json: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}
