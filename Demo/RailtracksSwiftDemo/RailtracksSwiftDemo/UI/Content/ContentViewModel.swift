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
    }
    
    var libVersion: String = RailtracksSwift.version
    var mode: ViewMode = .mathApple
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
}
