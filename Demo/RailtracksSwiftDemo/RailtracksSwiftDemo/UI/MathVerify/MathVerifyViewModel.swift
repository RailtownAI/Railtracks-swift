//
//  MathVerifyViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-20.
//

import Foundation
import RailtracksSwift
import Logging

/// Demonstrates agent-as-tool: a solver agent uses math tools to calculate,
/// then calls a verifier sub-agent to confirm the result before responding.
@Observable
class MathVerifyViewModel {
    let prompt: String = "What is 50 + 20 x 8 - 4 x 5? Give me the final answer in a single number without any description."
    var promptResult: String?

    func startPrompt() {
        let prompt = self.prompt
        Task { [weak self] in
            guard let apiKey = RailtracksSwift.getOpenAIAPIKey() else {
                Log.debug("No API key found")
                return
            }
            let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])

            let verifierAgent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                name: "MathVerifier",
                systemMessage: "You are a math verification assistant. Given a math problem and a proposed answer, verify whether the answer is correct. Respond with 'Correct' or 'Incorrect' followed by a brief explanation."
            )

            let verifierTool = RTSAgentTool(
                agent: verifierAgent,
                description: "Verifies a proposed answer to a math problem. Use this to double-check your calculated answer before responding.",
                parameters: RTSToolSchema(parameters: [
                    .init(name: "prompt", description: "The math problem and proposed answer to verify", type: .string)
                ])
            )

            let mathTools: [any RTSToolNode] = [
                AdditionTool(),
                SubtractionTool(),
                MultiplicationTool(),
                DivisionTool(),
                verifierTool
            ]

            let solverAgent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                name: "MathSolver",
                tools: mathTools,
                systemMessage: "You are a Math assistant. " +
                "Use the math tools to perform each calculation step. " +
                "If there is addition in the math, you must use the provided addition tool to perform the calculation. " +
                "If there is subtraction in the math, you must use the provided subtraction tool to perform the calculation. " +
                "If there is multiplication in the math, you must use the provided multiplication tool to perform the calculation. " +
                "If there is division in the math, you must use the provided division tool to perform the calculation. " +
                "After computing your final answer, use the MathVerifier tool to confirm it is correct before responding."
            )

            let flow = RTSFlow(title: "Math Verify flow")
            self?.promptResult = try? await flow.run(agent: solverAgent, prompt: prompt, gateway: gateway)
            Log.debug("obtained math verify result")
        }
    }
}
