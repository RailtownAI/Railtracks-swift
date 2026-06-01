//
//  OutputSchemaViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-06-01.
//

import Foundation
import RailtracksSwift
import Logging

/// Demonstrates agent-as-tool: a solver agent uses math tools to calculate,
/// then calls a verifier sub-agent to confirm the result before responding.
@Observable
class OutputSchemaViewModel {
    var jobURLString: String = ""
    var promptResult: String = ""
    var isRunning: Bool = false

    func startPrompt() {
        Task { [weak self] in
            self?.isRunning = true
            defer { self?.isRunning = false }
            guard let apiKey = RailtracksSwift.getOpenAIAPIKey() else {
                Log.debug("No API key found")
                return
            }
            guard let jobURL = URL(string: self?.jobURLString ?? "") else {
                Log.debug("Invalid job URL")
                return
            }
            
            let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])
            let flow = RTSFlow(title: "Extract Job Description")
            
            Log.debug("📤 Extract job description")
            let jobPageText = try await HTMLFetcher.fetchText(from: jobURL)
            let jobDescriptionPrompt = "You have been given the following job posting content:" + jobPageText
            Log.debug("📤 Extract job description: prompt: \(jobDescriptionPrompt)")
            let jobDescriptionResult = try await flow.run(
                agent: JobDescriptionAgent(),
                prompt: jobDescriptionPrompt,
                gateway: gateway
            )
            Log.debug("📤 Extract job description: raw result: \(jobDescriptionResult)")
            let jobDescription = try JobDescription.decode(from: jobDescriptionResult)
            self?.promptResult = String(describing: jobDescription)
            Log.debug("📤 Extract job description complete")
        }
    }
}
