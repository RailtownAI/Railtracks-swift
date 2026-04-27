//
//  ContentViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import RailtracksSwift

@Observable
class ContentViewModel {
    var title: String = "Hello, World!"
    var libVersion: String = RailtracksSwift.version
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
}
