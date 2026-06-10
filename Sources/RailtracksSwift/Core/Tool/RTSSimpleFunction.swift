//
//  RTSSimpleFunction.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation

public struct RTSSimpleFunction: RTSFunctionNode {
    enum CodingKeys: CodingKey {
        case id
        case name
    }
    
    public let id = UUID()
    let _name: String
    public var inputs: RTSInput
    public let callableRoutine: RTSClosure
    
    /// - Parameters:
    ///   - name: Identifier for this node, used in tracing output.
    ///   - prompt: Initial input string stored under the `"prompt"` key in `inputs` at creation time.
    ///   - routine: Closure that receives the prompt string and returns a result string.
    public init(name: String, prompt: String, routine: @escaping @Sendable (String) async throws -> String) {
        self._name = name
        self.inputs = ["prompt": .string(prompt)]
        self.callableRoutine = RTSClosure() { inputs in
            guard case .string(let requestString) = inputs["prompt"] else {
                throw RTSError.missingInput("prompt")
            }
            let result = try await routine(requestString)
            return ["result": .string(result)]
        }
    }
    
    /// pipeline terminal end function to unwrap Output from RTSNode.invoke()
    public func invokeForStringResponse() async throws -> String {
        let output = try await invoke()
        guard case .string(let responseString) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return responseString
    }
    
    public func name() -> String {
        return _name
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(_name, forKey: .name)
    }
}
