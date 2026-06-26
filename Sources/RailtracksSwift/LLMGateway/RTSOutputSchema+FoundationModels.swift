//
//  RTSOutputSchema+FoundationModels.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-01.
//

import Foundation
import FoundationModels

// These conversions are internal to the LLMGateway layer.
// Nothing outside of LLMGateway/ should call these directly.

@available(macOS 26, iOS 26, *)
extension RTSOutputSchema {
    func toFoundationModelsSchema() throws -> GenerationSchema {
        guard case .object(let objectName, let properties) = type else {
            throw RTSError.invalidSchema("RTSOutputSchema root must be an .object type")
        }
        var dependencies: [DynamicGenerationSchema] = []
        let root = DynamicGenerationSchema(
            name: objectName,
            properties: properties.map { $0.toFMDynamicProperty(collectingDependencies: &dependencies) }
        )
        return try GenerationSchema(root: root, dependencies: dependencies)
    }

    func toFMDynamicProperty(collectingDependencies deps: inout [DynamicGenerationSchema]) -> DynamicGenerationSchema.Property {
        DynamicGenerationSchema.Property(
            name: name,
            description: description,
            schema: type.toFMDynamic(collectingDependencies: &deps),
            isOptional: isOptional
        )
    }
}

@available(macOS 26, iOS 26, *)
extension RTSOutputSchema.SchemaType {
    func toFMDynamic(collectingDependencies deps: inout [DynamicGenerationSchema]) -> DynamicGenerationSchema {
        switch self {
        case .string:  return DynamicGenerationSchema(type: String.self)
        case .number:  return DynamicGenerationSchema(type: Double.self)
        case .boolean: return DynamicGenerationSchema(type: Bool.self)
        case .array(let elementType):
            return DynamicGenerationSchema(arrayOf: elementType.toFMDynamic(collectingDependencies: &deps))
        case .stringEnum(let name, let choices):
            deps.append(DynamicGenerationSchema(name: name, anyOf: choices))
            return DynamicGenerationSchema(referenceTo: name)
        case .object(let name, let properties):
            deps.append(DynamicGenerationSchema(
                name: name,
                properties: properties.map { $0.toFMDynamicProperty(collectingDependencies: &deps) }
            ))
            return DynamicGenerationSchema(referenceTo: name)
        }
    }
}
