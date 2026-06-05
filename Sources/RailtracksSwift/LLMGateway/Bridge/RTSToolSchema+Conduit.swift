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
        GenerationSchema(
            type: GeneratedContent.self,
            properties: parameters.map { param in
                switch param.type {
                case .string:
                    return GenerationSchema.Property(name: param.name, description: param.description, type: String.self)
                case .number:
                    return GenerationSchema.Property(name: param.name, description: param.description, type: Double.self)
                case .bool:
                    return GenerationSchema.Property(name: param.name, description: param.description, type: Bool.self)
                case .array(let elementType):
                    switch elementType {
                    case .string:
                        return GenerationSchema.Property(name: param.name, description: param.description, type: [String].self)
                    case .number:
                        return GenerationSchema.Property(name: param.name, description: param.description, type: [Double].self)
                    case .bool:
                        return GenerationSchema.Property(name: param.name, description: param.description, type: [Bool].self)
                    case .array:
                        return GenerationSchema.Property(name: param.name, description: param.description, type: [String].self)
                    }
                }
            }
        )
    }
}
