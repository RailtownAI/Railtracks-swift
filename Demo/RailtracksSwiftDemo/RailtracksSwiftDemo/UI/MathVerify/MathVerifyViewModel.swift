//
//  MathVerifyViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-20.
//

import Foundation
import Combine
import RailtracksSwift
import Logging

/// Demonstrates agent-as-tool: a solver agent uses math tools to calculate,
/// then calls a verifier sub-agent to confirm the result before responding.
@Observable
class MathVerifyViewModel {
    let prompt: String = "What is 50 + 20 x 8 - 4 x 5? Give me the final answer in a single number without any description."
    var promptResult: String?
    var nodeStatusLog: String = ""
    var isRunning = false
    var isShowingKeyPrompt = false

    func startPrompt() {
        guard let apiKey = KeychainHelper.readOpenAIKey() else {
            isShowingKeyPrompt = true
            return
        }
        let prompt = self.prompt
        nodeStatusLog = ""
        isRunning = true
        Task { [weak self] in
            defer { self?.isRunning = false }
            let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])

            // Tier 3: independently re-computes the answer using math tools
            let stepCalculatorAgent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt5Mini.modelIDString),
                name: "MathStepCalculator",
                tools: [AdditionTool(), SubtractionTool(), MultiplicationTool(), DivisionTool()],
                systemMessage: "You are a step-by-step math calculator. " +
                "Given a math problem, use the provided math tools to compute each operation in the correct order. " +
                "Return only the final numeric result."
            )

            let stepCalculatorTool = RTSAgentTool(
                agent: stepCalculatorAgent,
                description: "Independently re-computes a math problem step by step using math tools. Use this to get an independent calculation to compare against a proposed answer.",
                parameters: RTSToolSchema(parameters: [
                    .init(name: "prompt", description: "The math problem to independently compute", type: .string)
                ])
            )

            // Tier 2: verifies by delegating re-computation to MathStepCalculator
            let verifierAgent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt5Mini.modelIDString),
                name: "MathVerifier",
                tools: [stepCalculatorTool],
                systemMessage: "You are a math verification assistant. " +
                "Given a math problem and a proposed answer, use the MathStepCalculator tool to independently re-compute the answer. " +
                "Compare the re-computed result with the proposed answer and respond with 'Correct' or 'Incorrect' followed by a brief explanation."
            )

            let verifierTool = RTSAgentTool(
                agent: verifierAgent,
                description: "Verifies a proposed answer by delegating an independent re-computation to a step calculator sub-agent.",
                parameters: RTSToolSchema(parameters: [
                    .init(name: "prompt", description: "The math problem and proposed answer to verify", type: .string)
                ])
            )

            // Tier 1: solves the problem then calls the verifier
            let solverAgent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                name: "MathSolver",
                tools: [AdditionTool(), SubtractionTool(), MultiplicationTool(), DivisionTool(), verifierTool],
                systemMessage: "You are a Math assistant. " +
                "Use the math tools to perform each calculation step by step. " +
                "After computing your final answer, use the MathVerifier tool to confirm it is correct before responding."
            )

            let flow = RTSFlow(title: "Math Verify flow")
            var cancellables = Set<AnyCancellable>()
            flow.nodeStatusPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    let label: String
                    switch status.state {
                    case .executing:
                        label = "⏳ \(status.nodeName)"
                    case .completed:
                        label = "✅ \(status.nodeName)"
                    case .failed(let error):
                        label = "❌ \(status.nodeName): \(error)"
                    }
                    if self?.nodeStatusLog.isEmpty == true {
                        self?.nodeStatusLog = label
                    } else {
                        self?.nodeStatusLog += "\n" + label
                    }
                }
                .store(in: &cancellables)

            self?.promptResult = try? await flow.run(agent: solverAgent, prompt: prompt, gateway: gateway)
            Log.debug("obtained math verify result")
        }
    }
}
