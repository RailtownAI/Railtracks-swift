//
//  RTFlow.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation

public class RTFlow {
    let title: String
    let entryPoint: (String) async -> String
    
    init(title: String, entryPoint: @escaping (String) async -> String) {
        self.title = title
        self.entryPoint = entryPoint
    }
    
    func invoke(_ prompt: String) async -> String {
        return await self.entryPoint(prompt)
    }
}
