//
//  MathErrorViewModel.swift
//  RailtracksSwiftDemo
//

import Foundation
import RailtracksSwift
import Combine
import Logging

/// Math demo that intentionally triggers a tool error (division by zero) to
/// exercise error edge recording in the JSON trace and run status propagation.
@Observable
class MathErrorViewModel {
    let prompt = "What is (10 + 5) x 2 / 0? Use the provided tools for every operation."
    var promptResult: String = ""
    /// Shows the trace file URL once written — populated even when the run fails, which is
    /// the visible proof that a failed run still produces its JSON trace.
    var traceStatus: String = ""
    var isRunning = false
    var isShowingKeyPrompt = false

    private var cancellables = Set<AnyCancellable>()

    /// Observe the flow's trace-file output so we can confirm the JSON is written even when
    /// `flow.run` throws. Subscribe before calling `run`.
    private func observeTrace(_ flow: RTSFlow) {
        cancellables.removeAll()
        flow.outputFileURLPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                switch result {
                case .success(let url):
                    self?.traceStatus = "Trace written: \(url.lastPathComponent)"
                case .failure(let error):
                    self?.traceStatus = "Trace write failed: \(error)"
                }
            }
            .store(in: &cancellables)
    }

    /// Deterministically drives `flow.run` down its error path via an orchestrator that
    /// throws — no LLM/API key needed. Confirms the run rethrows *and* the trace is written.
    func startForceThrow() {
        resetOutput()
        isRunning = true
        Task { [weak self] in
            defer { self?.isRunning = false }
            self?.promptResult = "waiting..."
            let flow = RTSFlow(title: "Throwing Workflow")
            self?.observeTrace(flow)
            do {
                _ = try await flow.run(ThrowingWorkflow(), input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
                self?.promptResult = "n/a — expected a failure"
            } catch {
                self?.promptResult = "Failed as expected: \(error)"
                Log.debug("force-throw flow failed as expected: \(error)")
            }
        }
    }

    private func resetOutput() {
        promptResult = ""
        traceStatus = ""
    }

    func startPrompt() {
        guard let apiKey = KeychainHelper.readOpenAIKey() else {
            isShowingKeyPrompt = true
            return
        }
        let prompt = self.prompt
        resetOutput()
        isRunning = true
        Task { [weak self] in
            defer { self?.isRunning = false }
            self?.promptResult = "waiting..."
            let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])

            let tools: [any RTSToolNode] = [
                AdditionErrorTool(),
                MultiplicationErrorTool(),
                DivisionErrorTool()
            ]

            let flow = RTSFlow(title: "Math Error")
            self?.observeTrace(flow)

            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                tools: tools,
                systemMessage: "You are a Math assistant. " +
                "You must use the provided tools for every arithmetic operation — no mental calculation. " +
                "If there is addition, use the Addition tool. " +
                "If there is multiplication, use the Multiplication tool. " +
                "If there is division, use the Division tool."
            )

            Log.debug("starting math error prompt...")
            do {
                self?.promptResult = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
            } catch {
                self?.promptResult = "Flow failed: \(error)"
                Log.debug("math error flow failed: \(error)")
            }
            Log.debug("math error prompt done")
        }
    }
}
