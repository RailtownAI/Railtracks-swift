//
//  AppleEmbeddingViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-10-21.
//

import Foundation
import NaturalLanguage
import RailtracksSwiftRAG

/// A harness for getting the on-device embedding model onto the device: check, load without
/// downloading, or prepare with a timeout, and cancel while waiting.
///
/// Built to try `prepare(timeout:)` where the assets are missing — a Simulator, where the request
/// has been seen never to answer, or a language whose asset the device lacks. Each Prepare tap is
/// a separate caller with **its own embedder**, as separate indexes in an app would be, so tapping
/// it twice shows two callers sharing one download, and one timing out without affecting the other.
/// The library logs the request itself (started once, and its real result) to the Xcode console.
@MainActor
@Observable
class AppleEmbeddingViewModel {

    // MARK: - Choices

    /// Which model to ask for. Languages sharing a script share an asset, so these are one per
    /// script: on a device that has the English (Latin) asset, the others are likely missing.
    enum LanguageChoice: String, CaseIterable, Identifiable {
        case english
        case russian
        case japanese
        case arabic
        case hindi

        var id: String {
            rawValue
        }

        var language: NLLanguage {
            switch self {
            case .english:
                return .english
            case .russian:
                return .russian
            case .japanese:
                return .japanese
            case .arabic:
                return .arabic
            case .hindi:
                return .hindi
            }
        }

        var title: String {
            switch self {
            case .english:
                return "English (Latin)"
            case .russian:
                return "Russian (Cyrillic)"
            case .japanese:
                return "Japanese"
            case .arabic:
                return "Arabic"
            case .hindi:
                return "Hindi (Devanagari)"
            }
        }
    }

    /// How long Prepare waits. Short ones exist to time out on purpose, even where a download
    /// would eventually succeed.
    enum TimeoutChoice: String, CaseIterable, Identifiable {
        case zero
        case twoSeconds
        case tenSeconds
        case libraryDefault
        case unbounded

        var id: String {
            rawValue
        }

        var timeout: Duration? {
            switch self {
            case .zero:
                return .zero
            case .twoSeconds:
                return .seconds(2)
            case .tenSeconds:
                return .seconds(10)
            case .libraryDefault:
                return RTSRAGAppleEmbedding.defaultPrepareTimeout
            case .unbounded:
                return nil
            }
        }

        var title: String {
            switch self {
            case .zero:
                return "0 s"
            case .twoSeconds:
                return "2 s"
            case .tenSeconds:
                return "10 s"
            case .libraryDefault:
                return "Default"
            case .unbounded:
                return "None"
            }
        }
    }

    // MARK: - State

    var languageChoice: LanguageChoice = .english
    var timeoutChoice: TimeoutChoice = .tenSeconds
    var statusLog = ""
    /// The embedder of the last caller whose prepare succeeded, for Embed Sample.
    private(set) var readyEmbedder: RTSRAGAppleEmbedding?
    private var waitingCallers: [Int: Task<Void, Never>] = [:]
    private var nextCallerNumber = 1

    var waitingCount: Int {
        waitingCallers.count
    }

    var environmentNote: String {
        #if targetEnvironment(simulator)
        return "Running in a Simulator: the asset request may never answer here."
        #else
        return "Running on a device: a missing asset downloads (about 100 MB) and stays installed."
        #endif
    }

    // MARK: - Actions

    /// `assetsAvailable`: answers without building an embedder or loading anything.
    func checkAssets() {
        let available = RTSRAGAppleEmbedding.assetsAvailable(language: languageChoice.language)
        append("\(languageChoice.title): assets on device: \(available ? "yes" : "no")")
    }

    /// `loadIfAvailable`: never downloads.
    func loadIfAvailable() {
        guard let embedder = makeEmbedder() else {
            return
        }
        let title = languageChoice.title
        Task {
            do {
                if try await embedder.loadIfAvailable() {
                    readyEmbedder = embedder
                    append("\(title): loaded without downloading")
                } else {
                    append("\(title): not on device; nothing downloaded")
                }
            } catch {
                append("\(title): assets present but failed to load: \(error)")
            }
        }
    }

    /// `prepare(timeout:)`, as a new caller each tap. Cancelling the task is the whole of the
    /// cancellation wiring — it reaches the wait inside the library because `prepare` is awaited
    /// directly in this task.
    func startPrepare() {
        guard let embedder = makeEmbedder() else {
            return
        }
        let callerNumber = nextCallerNumber
        nextCallerNumber += 1
        let timeoutChoice = timeoutChoice
        let label = "caller #\(callerNumber) (\(languageChoice.title), timeout \(timeoutChoice.title))"
        append("\(label): preparing")

        waitingCallers[callerNumber] = Task {
            let clock = ContinuousClock()
            let started = clock.now
            do {
                try await embedder.prepare(timeout: timeoutChoice.timeout)
                readyEmbedder = embedder
                append("\(label): ready after \(Self.format(clock.now - started))")
            } catch is CancellationError {
                append("\(label): cancelled after \(Self.format(clock.now - started))")
            } catch RTSRAGError.embeddingModelNotReady(let reason) {
                append("\(label): not ready after \(Self.format(clock.now - started)): \(reason)")
            } catch RTSRAGError.embeddingModelUnavailable(let reason) {
                append("\(label): unavailable after \(Self.format(clock.now - started)): \(reason)")
            } catch {
                append("\(label): failed after \(Self.format(clock.now - started)): \(error)")
            }
            waitingCallers[callerNumber] = nil
        }
    }

    /// The Cancel button: cancels every waiting caller. The download itself keeps running.
    func cancelWaiting() {
        append("cancelling \(waitingCallers.count) waiting caller(s)")
        for task in waitingCallers.values {
            task.cancel()
        }
    }

    /// Proves the prepared model works, not merely that prepare returned.
    func embedSample() {
        guard let embedder = readyEmbedder else {
            return
        }
        Task {
            do {
                let result = try await embedder.embed(["The refund policy is thirty days."])
                let dimension = result.vectors.first?.count ?? 0
                append("embedded a sample sentence: \(dimension)-dimension vector")
            } catch {
                append("embedding the sample failed: \(error)")
            }
        }
    }

    // MARK: - Log

    func clearLog() {
        statusLog = ""
    }

    private func append(_ message: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        statusLog += "\(stamp)  \(message)\n"
    }

    // MARK: - Helpers

    private func makeEmbedder() -> RTSRAGAppleEmbedding? {
        do {
            return try RTSRAGAppleEmbedding(language: languageChoice.language)
        } catch {
            append("\(languageChoice.title): no embedder: \(error)")
            return nil
        }
    }

    private static func format(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
    }
}
