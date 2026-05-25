//
//  RTSOutputSchema+GenerationSchema.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-25.
//

import Foundation
import Conduit

///  RTSOutputSchema → GenerationSchema conversion
extension RTSOutputSchema {
    func toGenerationSchema() throws -> GenerationSchema {
        guard case .object(let objectName, let properties) = type else {
            throw RTSError.invalidInvocation("RTSOutputSchema root must be an .object type")
        }
        var dependencies: [DynamicGenerationSchema] = []
        let root = DynamicGenerationSchema(
            name: objectName,
            properties: properties.map { $0.toDynamicProperty(collectingDependencies: &dependencies) }
        )
        return try GenerationSchema(root: root, dependencies: dependencies)
    }

    func toDynamicProperty(collectingDependencies deps: inout [DynamicGenerationSchema]) -> DynamicGenerationSchema.Property {
        DynamicGenerationSchema.Property(
            name: name,
            description: description,
            schema: type.toDynamic(collectingDependencies: &deps),
            isOptional: isOptional
        )
    }
}

///  RTSOutputSchema.SchemaType → DynamicGenerationSchema conversion
extension RTSOutputSchema.SchemaType {
    func toDynamic(collectingDependencies deps: inout [DynamicGenerationSchema]) -> DynamicGenerationSchema {
        switch self {
        case .string:  return DynamicGenerationSchema(type: String.self)
        case .number:  return DynamicGenerationSchema(type: Double.self)
        case .boolean: return DynamicGenerationSchema(type: Bool.self)
        case .array(let elementType):
            return DynamicGenerationSchema(arrayOf: elementType.toDynamic(collectingDependencies: &deps))
        case .stringEnum(let name, let choices):
            deps.append(DynamicGenerationSchema(name: name, anyOf: choices))
            return DynamicGenerationSchema(referenceTo: name)
        case .object(let name, let properties):
            deps.append(DynamicGenerationSchema(
                name: name,
                properties: properties.map { $0.toDynamicProperty(collectingDependencies: &deps) }
            ))
            return DynamicGenerationSchema(referenceTo: name)
        }
    }
}
