//
//  MathErrorViewModel.swift
//  RailtracksSwiftDemo
//

import Foundation
import RailtracksSwift
import Logging

/// Math demo that intentionally triggers a tool error (division by zero) to
/// exercise error edge recording in the JSON trace and run status propagation.
@Observable
class MathErrorViewModel {
    let prompt = "What is (10 + 5) x 2 / 0? Use the provided tools for every operation."
    var promptResult: String = ""

    func startPrompt() {
        let prompt = self.prompt
        Task { [weak self] in
            guard let apiKey = RailtracksSwift.getOpenAIAPIKey() else {
                Log.debug("No API key found")
                return
            }
            self?.promptResult = "waiting..."
            let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])

            let tools: [any RTSToolNode] = [
                AdditionErrorTool(),
                MultiplicationErrorTool(),
                DivisionErrorTool()
            ]

            let flow = RTSFlow(title: "Math Error")

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
