//
//  RTSStamp.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation

/// Represent a single stamping of time, step index, and event
struct RTSStamp: Codable {
    enum Event: Codable {
        case startCreate(String)
        case create(String, String)
        case finishExecution(String)
        
        var identifier: String {
            switch self {
            case .startCreate(let subject):
                return "START CREATED \(subject)"
            case .create(let actor, let subject):
                return "\(actor) CREATED \(subject)"
            case .finishExecution(let subject):
                return "Finished executing \(subject)"
            }
        }
    }
    
    /// Step index
    let stepIndex: Int
    
    /// UTC epoch time
    let timestamp: Date
    
    /// Event
    let event: Event
    
    init(stepIndex: Int, event: RTSStamp.Event) {
        self.stepIndex = stepIndex
        self.timestamp = Date()
        self.event = event
    }
}
