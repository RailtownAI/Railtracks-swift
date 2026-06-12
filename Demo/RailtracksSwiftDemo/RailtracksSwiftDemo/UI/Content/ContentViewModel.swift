//
//  ContentViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import Logging
import RailtracksSwift

@Observable
class ContentViewModel {
    enum ViewMode {
        case simple
        case math
        case mathApple
        case mathVerify
        case mathError
        case outputSchema
    }
    
    var libVersion: String = RailtracksSwift.version
    var mode: ViewMode = .mathError
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
}
