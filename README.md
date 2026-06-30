# RailtracksSwift

A Swift 6 library for building agentic LLM pipelines with tool-calling support. Agents and tool invocations are automatically traced into a flow graph exported as JSON for visualization.

## Requirements

- macOS 26+ / iOS 26+
- Swift 6

## Supported LLM Providers

| Provider | Enum case |
|---|---|
| OpenAI | `.openAI(modelIDString:)` |
| Apple Intelligence (on-device) | `.appleAI` |

## Quick Start

### OpenAI

```swift
import RailtracksSwift

// 1. Define tools
struct AdditionTool: RTSToolNode {
    let id = UUID()
    let toolName = "Addition"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(a) = inputs["a"] else { throw RTSError.missingInput("a") }
        guard case let .number(b) = inputs["b"] else { throw RTSError.missingInput("b") }
        return ["result": .number(a + b)]
    }
    var toolDescription = "Adds two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "a", description: "First number", type: .number),
            .init(name: "b", description: "Second number", type: .number)
        ])
    }
}

// 2. Create agent
let agent = RTSAgent(
    llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
    tools: [AdditionTool()],
    systemMessage: "You are a math assistant. Use the provided tools to solve math problems."
)

// 3. Run
let gateway = RTSLLMGateway(apiKeys: [.openAI: "<your-api-key>"])
let flow = RTSFlow(title: "Math Assistant")
let result = try await flow.run(agent: agent, prompt: "What is 12 + 8?", gateway: gateway)
```

### Apple Intelligence (on-device)

Tools for Apple Intelligence must conform to `RTSAppleAIToolNode`, which bridges to FoundationModels and auto-derives the parameter schema from `@Generable Arguments`.

```swift
import RailtracksSwift
import FoundationModels

struct AdditionToolApple: RTSAppleAIToolNode {
    typealias Output = String

    let id = UUID()
    let toolName = "Addition"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(a) = inputs["a"] else { throw RTSError.missingInput("a") }
        guard case let .number(b) = inputs["b"] else { throw RTSError.missingInput("b") }
        return ["result": .number(a + b)]
    }
    var toolDescription = "Adds two numbers and returns the result."

    // parameterSchema and call(arguments:) are provided automatically
    @Generable struct Arguments: Encodable {
        @Guide(description: "First number") var a: Double
        @Guide(description: "Second number") var b: Double
    }
}

// Check availability before running
guard case .available = SystemLanguageModel.default.availability else {
    // handle unavailable
    return
}

let agent = RTSAgent(
    llmProvider: .appleAI,
    tools: [AdditionToolApple()],
    systemMessage: "You are a math assistant. Use the provided tools to solve math problems."
)

let gateway = RTSLLMGateway(apiKeys: [:])
let flow = RTSFlow(title: "Math Assistant (AppleAI)")
let result = try await flow.run(agent: agent, prompt: "What is 12 + 8?", gateway: gateway)
```

## Core Concepts

### RTSFlow

The entry point. Creates and manages a single pipeline run, wires up the flow graph collector, and returns the agent's string result.

```swift
let flow = RTSFlow(title: "My Flow")
let result = try await flow.run(agent:prompt:gateway:systemMessage:)
```

A JSON trace file is written on completion. Subscribe to `outputFileURLPublisher` to receive the file URL:

```swift
flow.outputFileURLPublisher
    .sink { result in
        switch result {
        case .success(let url): 
            print("Trace written to \(url)")
        case .failure(let error): 
            print("Trace write failed: \(error)")
        }
    }
    .store(in: &cancellables)
```

Subscribe to `nodeStatusPublisher` to observe each node's execution state in real time, including nested sub-agents:

```swift
flow.nodeStatusPublisher
    .receive(on: DispatchQueue.main)
    .sink { status in
        switch status.state {
        case .executing: 
            print("⏳ \(status.nodeName)")
        case .completed: 
            print("✅ \(status.nodeName)")
        case .failed(let error): 
            print("❌ \(status.nodeName): \(error)")
        }
    }
    .store(in: &cancellables)

let result = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
```

`nodeStatusPublisher` emits for every node — agents, tools, and sub-agents — using the same `runID`-stamped event infrastructure as the JSON trace. Subscribe before calling `run` to capture all events.

### RTSAgent

Concrete agent implementation. Takes a provider, optional tools, and an optional system message.

```swift
RTSAgent(
    llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
    tools: [...],
    systemMessage: "...",
    outputSchema: nil,        // optional structured output
    outputSchemaMaxToken: 4096,
    inputGuardrails: [...],   // optional, see Guardrails
    outputGuardrails: [...]
)
```

### Structured Output

Annotate any `Codable` struct with `@RTSSchema` to generate an `RTSOutputSchema` the library can pass to the model. Supported by both `.openAI` and `.appleAI`.

```swift
@RTSSchema
struct JobResult: Codable {
    let title: String
    let summary: String
    let skills: [String]
}

let agent = RTSAgent(
    llmProvider: .appleAI,   // or .openAI(...)
    systemMessage: "Extract job info as structured data.",
    outputSchema: JobResult.rtsSchema
)

let raw = try await flow.run(agent: agent, prompt: jobText, gateway: gateway)
let result = try JobResult.decode(from: raw)
```

Nested types are supported — annotate each nested struct with `@RTSSchema` as well.

### RTSToolNode

Protocol for tools used with OpenAI (via Conduit). Implement `callableRoutine`, `toolDescription`, and `parameterSchema`.

```swift
struct MyTool: RTSToolNode {
    let id = UUID()
    let toolName = "MyTool"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in ... }
    var toolDescription = "..."
    var parameterSchema: RTSToolSchema { ... }
}
```

### RTSAppleAIToolNode

Extends `RTSToolNode` with FoundationModels' `Tool` protocol for Apple Intelligence support. Declare `@Generable struct Arguments: Encodable` with `@Guide` descriptions and the library provides `parameterSchema` and `call(arguments:)` automatically. The same `callableRoutine` runs for both OpenAI and Apple paths.

### RTSValue

A JSON-like enum used for all inputs and outputs in the pipeline.

```swift
public enum RTSValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RTSValue])
    case object([String: RTSValue])
}

typealias RTSInput  = [String: RTSValue]
typealias RTSOutput = [String: RTSValue]
```

### RTSLLMGateway

Instantiated with API keys at the app level. Builds provider-specific sessions per agent invocation.

```swift
// OpenAI
RTSLLMGateway(apiKeys: [.openAI: apiKey])

// Apple Intelligence (no key needed)
RTSLLMGateway(apiKeys: [:])
```

### RTSAgentTool

Wraps an `RTSAgentNode` as a tool so one agent can invoke another as part of its tool set.

```swift
let subAgent = RTSAgent(llmProvider: .openAI(...), ...)
let agentTool = RTSAgentTool(
    agent: subAgent,
    description: "...",
    parameters: RTSToolSchema(parameters: [
        .init(name: "query", description: "The question to answer", type: .string)
    ])
)

let orchestrator = RTSAgent(
    llmProvider: .openAI(...),
    tools: [agentTool]
)
```

Use `inputTransform` and `outputTransform` to adapt the data flowing into and out of the wrapped agent without modifying either agent's implementation:

```swift
RTSAgentTool(
    agent: subAgent,
    description: "...",
    parameters: RTSToolSchema(parameters: [
        .init(name: "query", description: "The question to answer", type: .string)
    ]),
    inputTransform: { inputs in
        // rename or inject keys before the sub-agent sees them
        var modified = inputs
        modified["prompt"] = inputs["query"]
        return modified
    },
    outputTransform: { outputs in
        // reshape the sub-agent's result before the parent LLM sees it
        return ["summary": outputs["result"] ?? .null]
    }
)
```

If `inputKeyPrompt` is missing from the inputs at call time, the entire input is serialised to a string and placed under `inputKeyPrompt` automatically, preventing a silent prompt-missing failure.

### Guardrails

Attach guardrails to an agent to inspect, rewrite, or block its **input** (before the LLM) and **output** (before the result is returned). Each guardrail returns `.allow`, `.block(reason)`, or `.transform(value)`. Guardrails run in array order; a `.transform` feeds the next, and the first `.block` short-circuits the rest and makes `flow.run` throw `RTSError.guardrailBlocked`. Every step is recorded in the JSON trace under the node's `guard_details`. Guardrails are per-agent, so they also apply to sub-agents on their own invocations.

```swift
let agent = RTSAgent(
    llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4oMini.modelIDString),
    systemMessage: "You are a helpful assistant.",
    inputGuardrails: [
        try RTSBlockTextInputGuardrail(pattern: #"(?i)ignore (all )?previous instructions"#),
        try RTSPIIRedactInputGuardrail(),
    ],
    outputGuardrails: [
        try RTSPIIRedactOutputGuardrail(),
    ]
)
```

Conform to `RTSAgentInputGuardrail` / `RTSAgentOutputGuardrail` to write your own — or use `RTSClosureInputGuardrail` / `RTSClosureOutputGuardrail` for inline checks:

```swift
struct MinLengthGuard: RTSAgentInputGuardrail {
    let name = "min-length"
    func check(_ input: RTSInput) async throws -> RTSInputGuardrailResult {
        guard case let .string(p)? = input["prompt"], p.count >= 3 else {
            return .block("Prompt too short")
        }
        return .allow()
    }
}
```

A blocked run is surfaced to the caller via the thrown error:

```swift
do {
    let answer = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
} catch let RTSError.guardrailBlocked(name, stage, reason) {
    print("Blocked by \(name) at \(stage): \(reason)")
}
```

#### Built-in guardrails

| Guardrail (input / output) | Action | Notes |
|---|---|---|
| `RTSLengthInputGuardrail` / `RTSLengthOutputGuardrail` | block | Caps total character count (defaults: 4096 in / 2048 out) |
| `RTSBlockTextInputGuardrail` / `RTSBlockTextOutputGuardrail` | block | Blocks on an ICU regex match; throwing init validates the pattern |
| `RTSPIIRedactInputGuardrail` / `RTSPIIRedactOutputGuardrail` | transform | Regex + Luhn redaction of email, phone, credit card, US SSN, CA SIN, IP, URL, IBAN; supports custom patterns |
| `RTSAppleAIPIIRedactInputGuardrail` / `RTSAppleAIPIIRedactOutputGuardrail` | transform | On-device, model-based PII redaction (names, addresses, etc.) for what regex can't catch. Requires macOS/iOS 26 + Apple Intelligence; **fails closed** (throws) when unavailable |

The on-device PII guard calls FoundationModels **directly** (not through the flow), so the raw pre-redaction text is never written to the trace — only the redacted result and the verdict counts.

## OpenAI Model IDs

```swift
RTSOpenAIModelID.gpt4o
RTSOpenAIModelID.gpt4oMini
RTSOpenAIModelID.gpt4Turbo
RTSOpenAIModelID.o1
RTSOpenAIModelID.o3Mini
// ...
```

Use `.modelIDString` to get the raw string for `RTSLLMProvider`.

## Error Handling

```swift
public enum RTSError: Error {
    case missingInput(String)
    case missingOutput(String)
    case encodingFailed(String?)
    case decodingFailed(String?)
    case writeFileFailed(String?)
    case invalidInvocation(String)
    case invalidSchema(String)
    case missingAPIKey(String)
    case providerUnavailable(String)                                   // e.g. AppleAI below macOS/iOS 26
    case guardrailBlocked(guardrailName: String, stage: RTSGuardrailStage, reason: String)
}
```

## Flow Graph Tracing

Every `RTSFlow.run` automatically:
- Traces all node create/finish events via `RTSNodeInvoker`
- Stamps each LLM message with the `runID` of the invocation that produced it
- Writes a JSON trace file on completion

The JSON schema is consumed by the Railtracks Python visualizer.

### Configuration

Set these once at app startup before any flow runs:

```swift
// Directory where flow graph JSON files are written. Defaults to the app's Documents directory.
RailtracksSwift.flowGraphOutputDirectory = URL(fileURLWithPath: "/custom/path")

// Set to false to suppress per-run debug message files (DEBUG builds only).
RailtracksSwift.debugMessageFileEnabled = false
```

## Package Dependencies

- [swift-conduit](https://github.com/RailtownAI/Conduit) — LLM backend (OpenAI and OpenRouter)
- [RailtracksInstrumentationKit](https://github.com/FabricioSffair/RailtracksInstrumentationKit) — Instruments signpost emission for live tracing
- [swift-log](https://github.com/apple/swift-log) — Logging
