//
//  JobDescriptionAgent.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-25.
//

import Foundation
import RailtracksSwift

@RTSSchema
struct JobHeader: Codable {
    let title: String
    let company: String
    let location: String
}

@RTSSchema
struct JobDescription: Codable {
    let jobHeader: JobHeader
    let responsibilities: [String]
    let qualifications: [String]
    let jobDetail: String
}

/// Agent that process a job text and extract it into JobDescription format as output
struct JobDescriptionAgent: RTSAgentNode {
    let id: UUID = UUID()
    let agentName: String
    let llmProvider: RTSLLMProvider
    let outputSchema: RTSOutputSchema?
    var tools: [any RTSToolNode] = []
    var inputs: RTSInput = [:]
    
    public init() {
        self.agentName = "Job Description Agent"
        self.llmProvider = .appleAI
        let systemMessage: String = Self.systemMessage
        self.outputSchema = JobDescription.rtsSchema
        
        self.inputs[inputKeySystemMessage] = .string(systemMessage)
    }
}

extension JobDescriptionAgent {
    static var systemMessage: String {
        return """
                You are an expert at identifying personally identifiable information (PII) in resumes. Your task is to analyze the provided resume and identify ALL instances of PII that should be anonymized for privacy protection.
                
                **CRITICAL**: Extract the EXACT text strings as they appear in the resume. Do not paraphrase or modify the actual values - copy them character-for-character.

                Please ensure that you redact the companies.
                
                **Identify these types of PII:**
                - Personal names (full names, first names, last names)

                - Email addresses (personal and professional)
                - Phone numbers (mobile, home, work)
                - Physical addresses (street addresses, cities if uncommon, postal codes)
                - Personal websites, portfolios, or LinkedIn URLs containing names
                - GitHub/GitLab usernames that reveal real names
                - Company names
                - Any other uniquely identifying information (personal project names if they contain PII)
                
                **DO NOT anonymize:**
                - Job titles
                - Skills, technologies, and programming languages
                - Educational institutions and degrees
                - Professional certifications
                - Generic project descriptions and accomplishments
                - Dates and durations
                
                **Instructions:**
                1. For each piece of PII found, provide the exact actual_value as it appears in the original text
                2. Assign a descriptive field_name (e.g., "full_name", "email", "phone", "address", "linkedin_url")
                3. Explain why this field should be hidden in reason_hidden
                4. Be thorough - missing PII defeats the purpose of anonymization
                5. Ensure you maintain proper latex formatting at all times

            job_description_agent:
              system: |
                You are an information extraction agent.

                Your task is to analyze raw job posting content (often HTML or poorly formatted text)
                and extract a structured job description that conforms EXACTLY to the provided output schema.

                The schema contains the following top-level fields:
                - jobHeader
                - responsibilities
                - qualifications
                - jobDetail

                =========================
                GENERAL RULES
                =========================

                1. Source of truth
                  - Use ONLY the provided job posting content.
                  - Do NOT infer, guess, or hallucinate information.
                  - If information is missing or unclear, use empty strings "" or empty lists [].

                2. HTML handling
                  - The input may contain raw HTML, scripts, navigation, or styling.
                  - Ignore non-job-related content (headers, footers, cookie banners, ads).
                  - Focus on the primary job posting body.

                =========================
                FIELD-SPECIFIC GUIDANCE
                =========================

                jobHeader:
                  - Populate the nested JobHeaders object.
                  - Extract:
                    - title: official job title as written
                    - company: hiring organization
                    - location: job location or remote status
                  - Do not normalize, abbreviate, or infer.
                  - If a header cannot be confidently determined, use an empty string.

                responsibilities:
                  - A list of core job duties.
                  - Extract from sections like:
                    "Responsibilities", "What you will do", "The role"
                  - Each item must be a single, concise responsibility.
                  - Do NOT include qualifications, skills, or requirements.
                  - No bullet symbols, numbering, or markdown.

                qualifications:
                  - A list of required or preferred qualifications.
                  - Extract from sections like:
                    "Qualifications", "Requirements", "What we’re looking for"
                  - Include education, experience, skills, certifications if explicitly stated.
                  - Each qualification must be its own list item.

                jobDetail:
                  - A concise paragraph summarizing the role.
                  - May include:
                    - Team context
                    - Technologies mentioned
                    - Company mission (if role-relevant)
                    - Seniority expectations
                  - Do NOT repeat responsibilities or qualifications verbatim.

                =========================
                OUTPUT CONSTRAINTS
                =========================

                - Output ONLY structured data matching the schema.
                - Do not include explanations, comments, or metadata.
                - Ensure lists contain only strings.
                - Accuracy is more important than completeness.
            """
    }
}

extension JobDescription {
    func toJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "UTF-8 encoding failed"))
        }
        return string
    }
}
