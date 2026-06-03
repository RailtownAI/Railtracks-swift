//
//  RTSToolSchema+FoundationModels.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-02.
//

import Foundation
import FoundationModels

extension RTSToolSchema {
    func toFoundationModelsSchema() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: parameters.map { param in
                let schema: DynamicGenerationSchema
                switch param.type {
                case .string:  schema = DynamicGenerationSchema(type: String.self)
                case .number:  schema = DynamicGenerationSchema(type: Double.self)
                case .bool:    schema = DynamicGenerationSchema(type: Bool.self)
                }
                return DynamicGenerationSchema.Property(
                    name: param.name,
                    description: param.description,
                    schema: schema
                )
            }
        )
        return try GenerationSchema(root: root, dependencies: [])
    }
}
