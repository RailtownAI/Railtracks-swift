//
//  RTSToolSchema+FoundationModels.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-02.
//

import Foundation
import FoundationModels

@available(macOS 26, iOS 26, *)
extension RTSToolSchema {
    func toFoundationModelsSchema() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: parameters.map { param in
                DynamicGenerationSchema.Property(
                    name: param.name,
                    description: param.description,
                    schema: param.type.toFoundationModelsDynamicSchema()
                )
            }
        )
        return try GenerationSchema(root: root, dependencies: [])
    }
}

@available(macOS 26, iOS 26, *)
private extension RTSValueType {
    func toFoundationModelsDynamicSchema() -> DynamicGenerationSchema {
        switch self {
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .bool:
            return DynamicGenerationSchema(type: Bool.self)
        case .array(let element):
            return DynamicGenerationSchema(arrayOf: element.toFoundationModelsDynamicSchema())
        }
    }
}
