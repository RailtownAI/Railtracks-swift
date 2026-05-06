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
        Log.setup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
