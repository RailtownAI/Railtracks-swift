//
//  RTSToolSchema+Conduit.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-02.
//

import Foundation
import Conduit

extension RTSToolSchema {
    func toGenerationSchema() -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: parameters.map { param in
                DynamicGenerationSchema.Property(
                    name: param.name,
                    description: param.description,
                    schema: param.type.toConduitDynamicSchema()
                )
            }
        )
        // Schema construction only fails for duplicate names or undefined refs —
        // neither applies to our flat, statically-defined parameter schemas.
        return (try? GenerationSchema(root: root, dependencies: [])) ?? GenerationSchema(type: GeneratedContent.self, properties: [])
    }
}

private extension RTSValueType {
    func toConduitDynamicSchema() -> DynamicGenerationSchema {
        switch self {
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .bool:
            return DynamicGenerationSchema(type: Bool.self)
        case .array(let element):
            return DynamicGenerationSchema(arrayOf: element.toConduitDynamicSchema())
        }
    }
}
