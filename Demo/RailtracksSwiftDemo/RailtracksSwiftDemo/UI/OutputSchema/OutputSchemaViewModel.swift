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
    var isShowingKeyPrompt = false

    func startPrompt() {
        guard let apiKey = KeychainHelper.readAnthropicKey() else {
            isShowingKeyPrompt = true
            return
        }
        Task { [weak self] in
            self?.isRunning = true
            defer { self?.isRunning = false }
            guard let jobURL = URL(string: self?.jobURLString ?? "") else {
                Log.debug("Invalid job URL")
                return
            }
            
            let gateway = RTSLLMGateway(apiKeys: [.anthropic: apiKey])
            let flow = RTSFlow(title: "Extract Job Description")
            
            Log.debug("📤 Extract job description")
            let jobDescriptionPrompt: String
            let jobDescriptionResult: String
            do {
                let jobPageText = try await HTMLFetcher.fetchText(from: jobURL)
                jobDescriptionPrompt = "You have been given the following job posting content:" + jobPageText
                Log.debug("📤 Extract job description: prompt: \(jobDescriptionPrompt)")
            } catch {
                Log.error("☠️📤 failed at fetching html for job description - error: \(error)")
                self?.promptResult = "Error: failed at fetching html for job description"
                return
            }
            
            do {
                jobDescriptionResult = try await flow.run(
                    agent: JobDescriptionAgent(),
                    prompt: jobDescriptionPrompt,
                    gateway: gateway
                )
                Log.debug("📤 Extract job description: raw result: \(jobDescriptionResult)")
            } catch {
                Log.error("☠️📤 failed at running job description agent - error: \(error)")
                self?.promptResult = "Error: failed at running job description agent"
                return
            }
            
            do {
                let jobDescription = try JobDescription.decode(from: jobDescriptionResult)
                self?.promptResult = String(describing: jobDescription)
                Log.debug("📤 Extract job description complete")
            } catch {
                Log.error("☠️📤 failed at parsing job description json - error: \(error)")
                self?.promptResult = "Error: failed at parsing job description json"
                return
            }
        }
    }
}
