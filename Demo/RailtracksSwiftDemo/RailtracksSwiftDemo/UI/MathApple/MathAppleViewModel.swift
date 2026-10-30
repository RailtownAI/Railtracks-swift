//
//  MathAppleViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation
import Combine
import FoundationModels
import RailtracksSwift
import Logging

/// Math agent demo using Apple on-device LLM via RTSAgent(llmProvider: .appleAI).
@available(macOS 26, iOS 26, *)
@Observable
class MathAppleViewModel {
    let prompt: String = MathToolsPrompt.prompt
    var promptResult: String = ""
    var nodeStatusLines: [String] = []
    var isRunning = false
    /// The task awaiting `flow.run`. Cancelling it is how a run is stopped.
    private var runTask: Task<Void, Never>?
    /// When Stop was pressed, to report how long the on-device model took to stop.
    private var stopPressedAt: ContinuousClock.Instant?

    func stopPrompt() {
        stopPressedAt = ContinuousClock.now
        runTask?.cancel()
    }

    func startPrompt() {
        let prompt = self.prompt
        nodeStatusLines = []
        stopPressedAt = nil
        isRunning = true
        runTask = Task { [weak self] in
            defer { self?.isRunning = false }
            switch SystemLanguageModel.default.availability {
            case .available:
                break
            case .unavailable(let reason):
                let message: String
                switch reason {
                case .appleIntelligenceNotEnabled:
                    message = "Apple Intelligence is not enabled. Go to Settings → Apple Intelligence & Siri to enable it."
                case .deviceNotEligible:
                    message = "This device does not support Apple Intelligence."
                case .modelNotReady:
                    message = "Apple Intelligence model is not ready yet. Please wait for it to finish downloading."
                default:
                    message = "Apple Intelligence is unavailable: \(reason)"
                }
                self?.promptResult = message
                return
            }

            self?.promptResult = "waiting..."
            let gateway = RTSLLMGateway(apiKeys: [:])

            let tools: [any RTSToolNode] = [
                AdditionToolApple(),
                SubtractionToolApple(),
                MultiplicationToolApple(),
                DivisionToolApple()
            ]

            let flow = RTSFlow(title: "Math Assistant (AppleAI)")

            let agent = RTSAgent(
                llmProvider: .appleAI,
                name: "AppleAI Math Assistant Agent",
                tools: tools,
                systemMessage: MathToolsPrompt.systemMessage
            )

            var cancellables = Set<AnyCancellable>()
            flow.nodeStatusPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    let label: String
                    switch status.state {
                    case .queued:
                        return
                    case .executing:
                        label = "⏳ \(status.nodeName)"
                    case .completed:
                        label = "✅ \(status.nodeName)"
                    case .failed(let error):
                        label = "❌ \(status.nodeName): \(error)"
                    case .cancelled:
                        label = "🛑 \(status.nodeName): cancelled"
                    }
                    self?.nodeStatusLines.append(label)
                }
                .store(in: &cancellables)

            Log.debug("starting prompt, waiting for response...")
            do {
                self?.promptResult = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
                Log.debug("obtained prompt result")
            } catch let error as RTSError {
                guard case .runTerminated = error else {
                    self?.promptResult = "Failed: \(error)"
                    Log.debug("math AppleAI run failed with \(error)")
                    return
                }
                // A Stop arrives here as `runTerminated(reason: cancelled)`, after the trace and
                // events are written.
                var result = "Stopped: \(error)"
                if let stopPressedAt = self?.stopPressedAt {
                    let stopTime = ContinuousClock.now - stopPressedAt
                    result += "\nStopped \(stopTime.formatted(.units(allowed: [.milliseconds]))) after Stop"
                }
                self?.promptResult = result
                Log.debug("math AppleAI run stopped with \(error)")
            } catch {
                self?.promptResult = "Failed: \(error)"
                Log.debug("math AppleAI run failed with \(error)")
            }
        }
    }
}
