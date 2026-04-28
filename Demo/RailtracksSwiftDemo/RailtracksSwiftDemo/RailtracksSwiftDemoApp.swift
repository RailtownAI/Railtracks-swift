//
//  RailtracksSwiftDemoApp.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import SwiftUI
import Logging

@main
struct RailtracksSwiftDemoApp: App {
    init() {
        _ = _loggingBootstrap
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
