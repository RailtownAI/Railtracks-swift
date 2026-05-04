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
    }
    
    var libVersion: String = RailtracksSwift.version
    var mode: ViewMode = .simple
    
//    var prompt: String = "What is 50 + 20 x 7? Just give me the final answer"
//    var promptResult: String?
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
}
