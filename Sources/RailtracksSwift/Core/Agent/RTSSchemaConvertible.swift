//
//  RTSSchemaConvertible.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-25.
//

/// Conforming types can describe their shape as an `RTSOutputSchema`.
///
/// Apply `@RTSSchema` to a struct for automatic synthesis.
public protocol RTSSchemaConvertible {
    static var rtsSchema: RTSOutputSchema { get }
}
