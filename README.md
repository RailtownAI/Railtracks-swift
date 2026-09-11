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

### RTSOrchestratorNode

A *function node* — deterministic Swift code that orchestrates agents (and other orchestrators) rather than letting an LLM decide the control flow. Conform to `RTSOrchestratorNode`, implement `run(_:context:)`, and invoke agents through the supplied `RTSRunContext` so they are traced as its children. Use it as a flow entry point when the sequencing (sequential, parallel, conditional) should live in code.

```swift
struct MathWorkflow: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName = "Math Workflow"   // trace label; defaults to the type name
    let agentA: RTSAgent
    let agentB: RTSAgent
    let agentC: RTSAgent

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        // C runs in parallel with the A → B chain.
        async let c = context.call(agentC, prompt: "What is 50 - 17?")

        // A → B run sequentially; A's answer feeds B.
        let a = try await context.call(agentA, prompt: "What is 12 x 8?")
        let b = try await context.call(agentB, prompt: "What is \(a) + 100?")

        return ["result": .string("A→B: \(b)\nC: \(try await c)")]
    }
}
```

Run it as the root of a flow with the orchestrator overload of `run`, which returns the node's full `RTSOutput`:

```swift
let flow = RTSFlow(title: "Math Workflow")
let output = try await flow.run(workflow, input: [:], gateway: gateway)
```

`RTSRunContext` offers three `call` overloads, each drawing a `thisNode → target` edge in the trace:

- `call(agent, prompt:systemMessage:)` — invoke an agent with a prompt; returns its text result.
- `call(agent, input:)` — invoke an agent with a full input dict; returns its full output.
- `call(orchestrator, input:)` — invoke another orchestrator (function → function composition).

Sessions for invoked agents are built on demand and subscribed to the flow's collector, so nested agents and sub-orchestrators show up as children in both the JSON trace and `nodeStatusPublisher`.

### RTSOrchestratorTool

Wraps an `RTSOrchestratorNode` as a tool so a parent agent's LLM can invoke an entire orchestrated workflow as a single tool call — the orchestrator counterpart to `RTSAgentTool`. It supports the same `inputTransform` / `outputTransform` hooks.

```swift
let workflowTool = RTSOrchestratorTool(
    orchestrator: MathWorkflow(agentA: ..., agentB: ..., agentC: ...),
    description: "Run the multi-step math workflow",
    parameters: RTSToolSchema(parameters: [
        .init(name: "problem", description: "The math problem to solve", type: .string)
    ])
)

let agent = RTSAgent(llmProvider: .openAI(...), tools: [workflowTool])
```

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
} catch let RTSError.guardrailBlocked(name, stage, reason, _) {
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
    case missingInput(String, context: RTSErrorContext)
    case missingOutput(String, context: RTSErrorContext)
    case encodingFailed(String?, context: RTSErrorContext)
    case decodingFailed(String?, context: RTSErrorContext)
    case writeFileFailed(String?, context: RTSErrorContext)
    case invalidInvocation(String, context: RTSErrorContext)
    case invalidSchema(String, context: RTSErrorContext)
    case missingAPIKey(String, context: RTSErrorContext)
    case providerUnavailable(String, context: RTSErrorContext)          // e.g. AppleAI below macOS/iOS 26
    case guardrailBlocked(
        guardrailName: String,
        stage: RTSGuardrailStage,
        reason: String,
        context: RTSErrorContext
    )
}
```

### Call-site context

Every case carries an `RTSErrorContext` describing where the error was raised. You never construct
it — write the case name as usual and it is filled in from the call site:

```swift
throw RTSError.missingInput("a")     // context = this file, this line, this function
```

```swift
public struct RTSErrorContext: Sendable, Equatable {
    public let file: String          // #fileID form, e.g. "MyApp/PaymentTool.swift"
    public let line: UInt
    public let function: String
}
```

Read it back with the `context` property:

```swift
do {
    let answer = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
} catch let error as RTSError {
    let context = error.context
    print("\(error) — thrown at \(context.file):\(context.line) in \(context.function)")
}
```

Three things to be aware of:

- **`RTSError`'s own string form omits the context**, so that the exported JSON trace keeps a stable
  format. Anything that needs the file and line must read `context` explicitly, as above.
- **`RTSError` already conforms to `CustomStringConvertible`.** To render errors differently, write
  your own helper function rather than an extension adding that conformance.
- **Errors raised inside the library report a location inside the library.** `guardrailBlocked`, for
  example, is always constructed at the same point in the guardrail runner, so its context is a fixed
  library location — the useful identifiers there are `guardrailName` and `stage`. The context is most
  informative for errors your own code raises.

If you build an error-reporting helper of your own, forward the literals so the context still points
at your caller rather than at the helper:

```swift
func reportFailure(
    _ detail: String,
    file: String = #fileID,
    line: UInt = #line,
    function: String = #function
) -> RTSError {
    .missingInput(detail, file: file, line: line, function: function)
}
```

### Using your own error type

Tools, agents, and orchestrators may throw any `Error`. It propagates out of `RTSFlow.run` unchanged
and is still recorded in the JSON trace, so you are not required to adopt `RTSError`.

Your own type will not carry call-site context unless you build it in. `RTSErrorContext` is public so
you can reuse it — give each case a labelled `context:` parameter, then add a same-named static
factory that defaults the literals:

```swift
enum PaymentError: Error {
    case declined(String, context: RTSErrorContext)

    // The `context:` label on the case is what lets this factory shadow it, so
    // `PaymentError.declined("card expired")` resolves here and captures the call site.
    static func declined(
        _ reason: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> PaymentError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .declined(reason, context: context)
    }
}

throw PaymentError.declined("card expired")
```

Call the factories directly. An unapplied reference such as
`let make: (String) -> PaymentError = PaymentError.declined` binds to the case, not the factory, and
will not compile.

## Flow Graph Tracing

Every `RTSFlow.run` automatically:
- Traces all node create/finish events via `RTSNodeInvoker`
- Stamps each LLM message with the `runID` of the invocation that produced it
- Writes a JSON trace file on completion

The JSON schema is consumed by the Railtracks Python visualizer.

### Configuration

Set these once at app startup before any flow runs:

```swift
// Root for everything the library writes. Defaults to the app's Documents directory.
// Fixed subfolders beneath it: `sessions` (traces), `events` (event logs), `evaluations`.
RailtracksSwift.outputDirectory = URL(fileURLWithPath: "/custom/path")

// Set to false to suppress per-run debug message files (DEBUG builds only).
RailtracksSwift.debugMessageFileEnabled = false
```

`flowGraphOutputDirectory`, `eventsOutputDirectory` and `evaluationOutputDirectory` are derived
and read-only — set the root instead, so redirecting one artifact cannot leave the others
behind.

## Observability Events

Alongside the flow-graph trace, every run publishes a stream of structured observability
events — `node.*`, `session.*`, `llm.*` and `middleware.*` — mirroring the Python engine's
event model. Subscribe to `eventPublisher` and process them however you like:

```swift
let cancellable = flow.eventPublisher.sink { event in
    print(event.eventType, event.payload)
}
```

Pass `RTSFlow(title:emitsEvents: false)` to turn the stream off; payloads are then never built,
so a flow with no consumer pays no encoding cost.

**Observation cannot slow a run down.** Events are delivered on a private serial queue, not on
the thread running your agents, so a slow subscriber can never stall node execution — add
`.receive(on:)` for your own queue on top if you like (`.main` for UI work is safe). Order is
preserved either way.

The trade-off is that delivery is asynchronous. `run` waits for the backlog before returning,
so the stream is complete once a run ends; if you need that guarantee at any other moment —
say, tearing a subscriber down mid-flow — call `await flow.flushEvents()` first. Note it
covers the library's queue only: a subscriber that adds its own `receive(on:)` must drain that
hop itself.

### Writing events to a file

Every flow writes its event stream to a JSONL file — one JSON object per line, named for the
session — through a built-in `RTSEventWriter`. There is nothing to wire:

```swift
let flow = RTSFlow(title: "Support")
let answer = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
```

Each run ends with a `session.completed` event, and writing it closes the file, so there is
nothing to remember per run either. To use the file, wait for it:

```swift
flow.eventWriter?.fileURLPublisher
    .sink { result in
        if case .success(let url) = result {
            print("events written to \(url.path)")
        }
    }
    .store(in: &subscriptions)
```

Files land in an `events` folder beside `sessions` and `evaluations`. Set the root once at
startup and all three move together:

```swift
RailtracksSwift.outputDirectory = URL(fileURLWithPath: "/custom/path")
// → /custom/path/sessions, /custom/path/events, /custom/path/evaluations
```

The subfolder names are fixed and the three per-artifact properties are read-only, so the layout
is something a consumer can rely on rather than three knobs that can drift apart. Missing
directories are created on first write.

Two runs on the same flow share a session id, so the second reopens the same file in append
mode and you get one file per session. The writer never throws: a write failure is logged and
reported through `fileURLPublisher`, never raised into your run.

### Turning it off, or owning it yourself

`savesEvents` follows `savesTrace` unless you set it, so a flow that persists a trace also
persists an event log:

```swift
RTSFlow(title: "Support", savesEvents: false)               // trace, no event log
RTSFlow(title: "Support", savesTrace: false, savesEvents: true)  // event log, no trace
RTSFlow(title: "Support", emitsEvents: false)               // no stream at all
```

To handle events yourself — your own file format, an upload, a live view — subscribe to
`eventPublisher`. That works whether or not the built-in log is on.

`RTSEventWriter` is read-only from outside: you can observe `flow.eventWriter` (its
`fileURLPublisher`, `lineCount`, `droppedEventCount`, `lateEventCount`), but only a flow can
create, subscribe or close one. That keeps a second writer from resolving to the same file path
and interleaving its writes with the flow's.

## Package Dependencies

- [swift-conduit](https://github.com/RailtownAI/Conduit) — LLM backend (OpenAI and OpenRouter)
- [RailtracksInstrumentationKit](https://github.com/FabricioSffair/RailtracksInstrumentationKit) — Instruments signpost emission for live tracing
- [swift-log](https://github.com/apple/swift-log) — Logging
