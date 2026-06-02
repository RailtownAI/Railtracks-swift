//
//  RTSToolSchema.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-05.
//

import Foundation

public struct RTSToolSchema: Sendable {
    public struct Parameter: Sendable {
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
