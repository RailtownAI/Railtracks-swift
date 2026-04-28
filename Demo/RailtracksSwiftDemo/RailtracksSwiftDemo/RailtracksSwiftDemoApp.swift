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
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
