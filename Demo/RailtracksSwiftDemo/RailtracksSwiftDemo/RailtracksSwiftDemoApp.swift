//
//  RailtracksSwiftDemoApp.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import SwiftUI
import Logging
import RailtownLogger

@main
struct RailtracksSwiftDemoApp: App {
    /// Paste the API key copied from the Railtown platform to enable Conductr error
    /// upload. With the placeholder left in place, configuration fails harmlessly and
    /// the app runs with error reporting disabled.
    private static let railtownAPIKey = "<PASTE-YOUR-RAILTOWN-API-KEY-HERE>"

    init() {
        Log.setup()
        do {
            try RailtownLogger.configure(
                apiKey: Self.railtownAPIKey,
                options: RailtownOptions(isInternalLoggingEnabled: true)
            )
        } catch {
            print("⚠️ RailtownLogger not configured: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
