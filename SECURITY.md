# Security Policy

This SECURITY.md describes safe usage, best practices, risk management and how to report vulnerabilities for the RailtracksSwift project.

RailtracksSwift is a Swift library for building agentic systems on Apple platforms. It orchestrates agents, tools, and LLM calls, but it does not itself provide sandboxing, network egress controls, or secret management. It is the Swift counterpart of the Python [Railtracks](https://github.com/RailtownAI/railtracks) framework.

## Audience

- App developers (primary): secure development and operation of agentic features in macOS and iOS apps
- Security/Compliance teams: risk identification and control points
- Researchers/Contributors: responsible disclosure and scope

## Scope

- In scope:
  - The `RailtracksSwift`, `RailtracksSwiftUI`, and `RailtracksSwiftRAG` library products in this repository
  - The demo app in `Demo/`, as far as it shows how the library is meant to be used
- Out of scope:
  - Tools, guardrails, loaders, and vector stores you write yourself, and third-party packages you combine with the library
  - LLM providers and the services behind them (OpenAI, Anthropic, Gemini, Apple Foundation Models, Private Cloud Compute, and any third-party `LanguageModel`)
  - Dependencies maintained in other repositories (for example Conduit, swift-log, swift-crypto, RailtracksInstrumentationKit). If an issue in one of them affects RailtracksSwift, report it to us and we will coordinate.
  - Your app, its distribution, and the devices and servers it runs on
  - Organization-specific data policies and compliance obligations

## What RailtracksSwift Is and Is Not

- Is: a library to compose agents, call tools, and talk to cloud and on-device models. It records execution traces and observability events, emits Instruments signposts, and offers retrieval (RAG) building blocks.
- Is not: a security sandbox, a secrets manager, a network firewall, or a data loss prevention system. It does not restrict what your tools can access, and it does not implement provider-side data privacy controls.

## Remote Resources

- Model pricing: to estimate cost, the library downloads a pricing table from LiteLLM's public GitHub repository at run time. It is read as data, never executed, and only affects reported cost figures.
- Third-party packages: tools, `LanguageModel` implementations, and other Swift packages run with your app's full privileges. Review their source and supply chain before adding them, and pin their versions.
- Model-generated content: never execute code, scripts, or commands that a model produced without validating them first.

## LLM/Provider Considerations

- Data privacy: prompts, tool arguments, and tool results are sent to whichever provider an agent uses. Understand each provider's data handling (retention, training usage, residency) and configure it to match your requirements. `.appleAI` runs on device; Private Cloud Compute and the cloud providers do not.
- Policy and safety: filter and validate user input according to your organization's policy and each provider's acceptable use policy. Treat LLM output as untrusted until validated.
- Prompt injection/jailbreaks: adversarial input, including text inside retrieved documents, can steer a model into misusing tools. Use input/output guardrails, narrowly scoped tools, and minimal permissions. The built-in guardrails (length limits, blocked text, PII redaction) reduce risk but are not a complete defense.

## Tools and Execution Safety

- Tools run arbitrary Swift code inside your app's process, with your app's entitlements, file access, and network access. Restrict each tool to what it needs; prefer read-only and narrowly scoped access.
- An agent decides when to call tools and with which arguments. Validate arguments inside each tool, and require user confirmation for destructive or irreversible actions.
- Agents used as tools (`RTSAgentTool`) inherit the same risks: a sub-agent can call its own tools on the parent model's instructions.

## API Keys and Secrets

- RailtracksSwift is not a secret store. `RTSLLMGateway` takes API keys from your app and holds them in memory only.
- Store keys in the Keychain, not in `UserDefaults`, source code, or bundled files.
- Do not ship provider API keys inside an app you distribute. Anything in an app bundle can be extracted. For distributed apps, route requests through a server you control, or use per-user credentials.
- Do not put secrets in prompts, system messages, or tool arguments: they end up in traces, event logs, and signposts (see below).

## Data Persistence and Logging

- Execution traces and event logs:
  - By default, each flow run writes a JSON trace to `sessions/` and a JSONL event log to `events/` under `RailtracksSwift.outputDirectory`, which defaults to the app's Documents directory. Evaluations write to `evaluations/`.
  - These files contain inputs and outputs, prompts and responses, intermediate messages, and tool arguments and results, including anything sensitive that passed through them.
  - They are not cleaned up or redacted automatically.
  - On iOS, the Documents directory is included in device backups, and it is visible in the Files app if the app enables file sharing.
  - Recommendations:
    - Turn persistence off in production when you do not need it: `RTSFlow(title:savesTrace: false)`. The event log follows `savesTrace` unless `savesEvents` is set.
    - Otherwise, point `RailtracksSwift.outputDirectory` at a location that is not shared or backed up (for example, Application Support with `isExcludedFromBackup`), apply an appropriate file protection class, and delete files you no longer need.
- Instruments signposts:
  - Flows emit signposts by default, including node inputs and outputs truncated to `RailtracksSwift.signpostIOContentLimit` characters (512 by default).
  - Anyone who can profile the process with Instruments can read them. Lower the limit, or pass your own `signpostEmitter`, if that content is sensitive.
- Retrieval (RAG) data:
  - Vector stores keep the text of every chunk they index. The Spotlight path donates chunks to the system's Core Spotlight index.
  - Index only content your app is allowed to keep, and remove sources with `removeSource(at:)` when the underlying data is deleted.
- Logging: library logs go through swift-log and may include node names, errors, and fragments of content. Keep production log levels minimal.

## Risks and Example Misuse Scenarios (with Mitigations)

- File access:
  - Risk: an agent with file tools reads sensitive files or deletes important ones.
  - Mitigations: restrict tools to a dedicated directory; rely on the App Sandbox; provide read-only access when feasible.
- External APIs:
  - Risk: an agent with write-capable credentials posts or deletes data.
  - Mitigations: prefer read-only keys; scope tokens to the endpoints needed; monitor usage.
- User data on device (contacts, photos, health, location):
  - Risk: a tool exposes personal data to a cloud model, or to an attacker through prompt injection.
  - Mitigations: expose only the fields a task needs; prefer on-device models for personal data; redact PII with guardrails before it leaves the device.
- Prompt injection/jailbreaks:
  - Risk: user input or retrieved documents steer the model into misusing tools or leaking data.
  - Mitigations: validate inputs; gate high-impact actions behind user confirmation; require structured output and verify it before acting.
- Runaway tool loops:
  - Risk: an agent keeps calling tools, multiplying cost and side effects.
  - Mitigations: keep tools idempotent where possible; cap tool rounds and concurrency; add timeouts and cancellation.

## Dependency and Supply Chain Hygiene

- Depend on RailtracksSwift through Swift Package Manager with a version requirement, and commit your `Package.resolved`.
- Track advisories for transitive dependencies, and use your organization's standard dependency and secret scanning.
- Review third-party tools and model packages before adding them to agents.

## Release Channels and Verification

- Official releases: tagged releases of this GitHub repository (`https://github.com/RailtownAI/Railtracks-swift`), consumed through Swift Package Manager.
- Verify that your package dependency points to this repository. Avoid unreviewed mirrors or forks.

## Reporting a Vulnerability

- Report suspected vulnerabilities privately to: [Security Email](mailto:security.railtracks@railtown.ai)
  - Alternatively, use GitHub's private vulnerability reporting: open the repository's [Security tab](https://github.com/RailtownAI/Railtracks-swift/security) and choose "Report a vulnerability".
  - Do not open public GitHub issues for security reports.
  - Include a detailed description, affected versions, a proof of concept if available, and your contact info.
  - Include your platform and OS version, and the provider involved, if relevant.
- We do not currently operate a public bug-bounty program. Disclosure timelines and remediations may vary by severity.

## In-Scope for Security Reports

Vulnerabilities in the library products in this repository that could lead to:
- Code execution or privilege escalation within the host app
- Unauthorized access to, or disclosure of, data the library persists or emits (traces, event logs, signposts, RAG indexes) when used as documented
- API keys being exposed through traces, logs, or errors when used as documented
- Integrity issues that let an attacker subvert tool invocation or agent routing without user authorization
- Documentation inaccuracies that materially mislead users about security behavior

## Out of Scope for Security Reports

- Misuse or insecure configuration of tools, services, or providers
- Vulnerabilities in LLM providers or in dependencies maintained elsewhere (report those upstream; tell us if they affect RailtracksSwift)
- Risks arising from user-authored tools or code not included in this repository
- API keys extracted from an app that bundled them
- Jailbroken devices, unpatched operating systems, or other insecure host environments
- Findings that require unrealistic attacker capabilities or non-default, undocumented configurations

## Open Source and Licensing Notice

This repository is open source and accepts public contributions. All code, issues and pull requests are publicly visible. See the LICENSE file for details. Software is provided "as is", without warranty of any kind, and no security or compliance guarantees are implied. You are responsible for evaluating fitness for your use case and for securing your own apps and data.

- Do not include secrets, personal data, or confidential information in code, issues, PRs, logs, traces, or example payloads.

## Privacy and Compliance

RailtracksSwift does not itself provide compliance guarantees. App developers are responsible for meeting regulatory obligations, including data minimization, retention, and residency, and for accurate App Store privacy disclosures covering any data sent to model providers.

## Safe-by-Practice Checklist

- Only add trusted tools and packages; review source and supply chain.
- Treat all LLM inputs and outputs as untrusted; validate before acting.
- Restrict tool capabilities and credentials to the minimum needed.
- Keep API keys in the Keychain, and out of distributed app bundles.
- Control persistence: disable traces in production or keep them out of shared and backed-up locations, and clean up after debugging.
- Review what signposts and logs expose in release builds.
- Pin dependencies and commit `Package.resolved`.

## Contact

- Security contact: [Security Email](mailto:security.railtracks@railtown.ai)
- Please include "[RailtracksSwift Security]" in the subject line.
- If you require an encrypted channel, please say so in your initial email. We can coordinate an alternative secure method of communication.

## Changes to This Policy

This document may be updated as the project evolves. Material changes will be noted in release notes.
