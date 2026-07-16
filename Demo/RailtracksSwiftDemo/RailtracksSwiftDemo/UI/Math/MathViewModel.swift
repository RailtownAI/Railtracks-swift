//
//  MathViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation
import RailtracksSwift
import Combine
import Logging

/// Math demo using a function-node (`MathWorkflow`) as the entry point, which
/// orchestrates three OpenAI agents: A → B in sequence, and C in parallel.
@Observable
class MathViewModel {
    let prompt: String = "A → B in sequence (12 × 8, then + 100); C in parallel (50 − 17)."
    var promptResult: String = ""
    var isRunning = false
    var isShowingKeyPrompt = false

    /// Left column — the sequential A → B track.
    var sequentialSteps: [RTSStepState] = [
        RTSStepState(id: "A", title: "Math Agent A", status: .pending, subtitle: "12 × 8", chips: []),
        RTSStepState(id: "B", title: "Math Agent B", status: .pending, subtitle: "A + 100", chips: []),
    ]
    /// Right column — the parallel C track.
    var parallelSteps: [RTSStepState] = [
        RTSStepState(id: "C", title: "Math Agent C", status: .pending, subtitle: "50 − 17", chips: []),
    ]

    private var cancellables = Set<AnyCancellable>()

    func startPrompt() {
        guard let apiKey = KeychainHelper.readOpenAIKey() else {
            isShowingKeyPrompt = true
            return
        }
        resetSteps()
        isRunning = true

        let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])
        let flow = RTSFlow(title: "Math Workflow")
        subscribe(to: flow)

        let workflow = MathWorkflow(
            agentA: Self.mathAgent(named: "Math Agent A"),
            agentB: Self.mathAgent(named: "Math Agent B"),
            agentC: Self.mathAgent(named: "Math Agent C")
        )

        Task { [weak self] in
            defer { self?.isRunning = false }
            Log.debug("starting math workflow...")
            do {
                let output = try await flow.run(workflow, input: [:], gateway: gateway)
                if case let .string(result) = output["result"] {
                    self?.promptResult = result
                } else {
                    self?.promptResult = "n/a"
                }
            } catch {
                self?.promptResult = "Error: \(error)"
            }
            Log.debug("math workflow finished")
        }
    }

    // MARK: - Step wiring

    private func subscribe(to flow: RTSFlow) {
        cancellables.removeAll()
        flow.nodeStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateStep(name: status.nodeName, state: status.state)
            }
            .store(in: &cancellables)
    }

    private func updateStep(name: String, state: RTSNodeStatus.State) {
        let status: StepStatus
        switch state {
        case .executing:
            status = .inProgress
        case .completed:
            status = .complete
        case .failed:
            status = .failed
        }
        if let index = sequentialSteps.firstIndex(where: { $0.title == name }) {
            sequentialSteps[index].status = status
        }
        if let index = parallelSteps.firstIndex(where: { $0.title == name }) {
            parallelSteps[index].status = status
        }
    }

    private func resetSteps() {
        promptResult = ""
        for index in sequentialSteps.indices {
            sequentialSteps[index].status = .pending
        }
        for index in parallelSteps.indices {
            parallelSteps[index].status = .pending
        }
    }

    private static func mathAgent(named name: String) -> RTSAgent {
        RTSAgent(
            llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4oMini.modelIDString),
            name: name,
            tools: [
                AdditionTool(),
                SubtractionTool(),
                MultiplicationTool(),
                DivisionTool()
            ],
            systemMessage: "You are a Math assistant. "
                + "If there is addition in the math, you must use the provided addition tool to perform the calculation. "
                + "If there is subtraction in the math, you must use the provided subtraction tool to perform the calculation. "
                + "If there is multiplication in the math, you must use the provided multiplication tool to perform the calculation. "
                + "If there is division in the math, you must use the provided division tool to perform the calculation. "
                + "You will calculate simple math problem asked by user."
        )
    }
}
