//
//  RTSToolSchema.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-05.
//

import Foundation
import ConduitAdvanced

public struct RTSToolSchema {
    public struct Parameter {
        public let name: String
        public let description: String
        public let type: RTSValueType
        public init(name: String, description: String, type: RTSValueType) {
            self.name = name
            self.description = description
            self.type = type
        }
    }
    
    public let parameters: [Parameter]
    public init(parameters: [Parameter]) {
        self.parameters = parameters
    }
}

extension RTSToolSchema {
    func toGenerationSchema() -> GenerationSchema {
        GenerationSchema(
            type: GeneratedContent.self,
            properties: parameters.map { param in
                switch param.type {
                case .double:
                    return GenerationSchema.Property(name: param.name, description: param.description, type: Double.self)
                case .string:
                    return GenerationSchema.Property(name: param.name, description: param.description, type: String.self)
                case .int:
                    return GenerationSchema.Property(name: param.name, description: param.description, type: Int.self)
                case .bool:
                    return GenerationSchema.Property(name: param.name, description: param.description, type: Bool.self)
                }
            }
        )
    }
} 
