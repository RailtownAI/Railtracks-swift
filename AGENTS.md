# AGENTS.md

This document provides context to understand the RailtracksSwift library and assist with development.

## Commands

```bash
# Build the library
swift build

# Run tests
swift test

# Clean build artifacts
swift package clean
```

The Demo app is an Xcode project at `Demo/RailtracksSwiftDemo/RailtracksSwiftDemo.xcodeproj` and must be built/run through Xcode.

It has two app targets over the same source folder. `RailtracksSwiftDemo` (macOS 15.6 / iOS 18.6) is the main one. `RailtracksSwiftDemoOS27` (macOS / iOS 27) is the same app plus the OS 27-only demos — today `Math(Claude)` — and is the only target that links `ClaudeForFoundationModels`: Swift refuses to import a module whose minimum OS is above the importing target's, `@available` or not. OS 27-only demo folders (`UI/MathClaude/`) are excluded from the main target by membership; the few lines in the shared `ContentView` / `ContentViewModel` that mention them sit behind `#if OS27`, a flag only the OS 27 target sets. Its bundle id differs, so its keychain is separate and it asks for the Anthropic key again on first use.

OpenAI API key is stored in the Keychain under service `ai.railtown.RailtracksSwiftDemo`, account `openai-api-key`. The demo app prompts for the key on first launch via `APIKeySetupView` and reads it via `KeychainHelper.readOpenAIKey()`.

## Coding style

- **No abbreviated variable names** when a clear full name is available. Prefer `detail`, `index`, `content`, `message` over `d`, `idx`, `c`, `m`. Idiomatic short names (`id`) and closure shorthand (`$0`) in trivial one-liners are fine.
- **One statement per line.** Do not chain statements with `;` (e.g. no `self.a = a; self.b = b` — split into separate lines).
- **No single-line function declarations.** A function/initializer/computed-property *declaration* always puts its body on its own line(s):

```swift
public init(epoch: TimeInterval) {
    self.epoch = epoch
}
```

  Not `public init(epoch: TimeInterval) { self.epoch = epoch }`. This applies only to declarations — inline closures at *call sites* (e.g. `items.map { $0.name }`) may stay on one line.
- **Parameter lists** (declarations *and* call sites) must not be grouped unevenly across lines (e.g. 2 on one line, then 3 on the next). Pick one of:
  - **All on one line** when the whole declaration/call line fits within **100 characters**.
  - **One parameter per line** when a single line would exceed 100 characters, in Xcode "⌃M" layout: the opening `(` stays on the declaration/call line, each parameter is on its own line, and the closing `)` is on its **own** line (before ` {`, or before the call's trailing `)`). Never place the first parameter on the `(` line, and never leave the closing `)` on the same line as the last parameter.

Example of the multi-line form:

```swift
public init(
    name: String,
    identifier: String,
    categories: [String]
) {
    self.name = name
    self.identifier = identifier
    self.categories = categories
}
```

- **Modifier order.** When any declaration carries multiple modifiers — properties, computed
  properties, subscripts, methods, or types — order them by category:
  1. **Access control** — `open`, `public`, `internal`, `fileprivate`, `private`
  2. **Overriding / finality** — `override`, `final`
  3. **Type-level** — `static`, `class`
  4. **Mutation** — `mutating`, `nonmutating`
  5. **Isolation** — `nonisolated`, `isolated`

  Include only the modifiers a declaration actually has, in this relative order (skip empty categories):

```swift
private mutating nonisolated func updateState() {   // method: access → mutation → isolation
    // …
}

public static let shared = Registry()               // property: access → type-level
```

## Architecture

RailtracksSwift is a Swift 6 library for orchestrating LLM agent pipelines. It wraps a provider-agnostic LLM communication layer (Conduit) and Apple Foundation Models, coordinates multi-step agent and tool invocations, and exports a structured JSON trace of each run for external visualization and analysis.

### Layers

```
┌─────────────────────────────────────────────────────────────┐
│  App Layer                                                  │
│  define agents · define tools · call flow.run               │
└──────────────────────────┬──────────────────────────────────┘
                           │ flow.run
                           │ ◄── outputFileURLPublisher
┌──────────────────────────▼──────────────────────────────────┐
│  Public API                                                 │
│                                                             │
│  ┌───────────┐   ┌─────────────┐   ┌──────────────────┐   │
│  │  RTSFlow  │   │  RTSAgent   │   │   RTSToolNode    │   │
│  │orchestrate│   │ LLM-backed  │   │ function-backed  │   │
│  │  a run    │   │    node     │   │      node        │   │
│  └───────────┘   └─────────────┘   └──────────────────┘   │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  Core                                                       │
│                                                             │
│  ┌──────────────────┐   ┌────────────────────────────────┐ │
│  │  RTSNodeInvoker  │   │    RTSFlowGraphCollector       │ │
│  │  stamp & publish │   │    accumulate events           │ │
│  │  node/edge events│   │    & messages                  │ │
│  └──────────────────┘   └──────────────┬───────────────┬─┘ │
│  ┌──────────────────┐                  │               │   │
│  │ RTSStampFactory  │           JSON file         Instruments
│  │ monotonic index  │          (Documents/)       (signpost)
│  └──────────────────┘                                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  Gateway          ← only layer that changes per provider    │
│                                                             │
│  ┌────────────────┐  ┌──────────────────────────────────┐  │
│  │ RTSLLMGateway  │  │       RTSLLMSession              │  │
│  │ select provider│  │  wraps provider session          │  │
│  │ build sessions │  │  publishes messages to collector │  │
│  └────────────────┘  └──────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ RTSConduitToolBridge                                │   │
│  │ adapts RTSToolNode → Conduit Tool protocol          │   │
│  └─────────────────────────────────────────────────────┘   │
└──────────────┬──────────────────────────┬───────────────────┘
               │                          │
┌──────────────▼──────────┐  ┌────────────▼────────────────┐
│  Conduit  (external)    │  │  Apple Foundation Models    │
│  ChatSession            │  │  (external, on-device)      │
│  ToolExecutor           │  │  LanguageModelSession       │
│  OpenAI / Anthropic /   │  │                             │
│  Gemini                 │  │                             │
└─────────────────────────┘  └─────────────────────────────┘
```

### Execution flow

```
RTSFlow.run(agent:prompt:gateway:)
  └── RTSNodeInvoker.invoke(_:input:session:)   // agent invocation
        ├── publishes RTSNodeEvent (create + finish)
        ├── publishes RTSEdgeEvent (create + finish)
        └── RTSAgentNode.invoke(runID:session:)
              └── RTSLLMSession.run(_:runID:)    // sends to LLM via Conduit
                    └── calls tool nodes via RTSConduitToolBridge
                          └── RTSNodeInvoker.invoke(_:input:)  // tool invocation
```

`RTSFlowGraphCollector` (an actor) subscribes to all node/edge event publishers on `RTSNodeInvoker`, funnels them into a single ordered `AsyncStream`, and drains that with one consumer so events are accumulated in publish order. When both the root node and root edge finish events are received, it writes the JSON file to the app's Documents directory and signals completion via an `AsyncStream`. `RTSFlow.run` awaits this signal before returning, which keeps all local instances alive.

### Key design decisions

**`runID` as the tracing thread** — Every node invocation receives a unique `runID`. Messages, node events, and edge events are all stamped with it. The collector uses `runID` as the key to associate messages with the node that produced them, with a message buffer to handle out-of-order delivery.

**Per-invocation node ids** — A node's *graph* identifier is minted per invocation (`invocationID` in `RTSNodeInvoker.invokeCore`), not per node instance, so a tool called N times yields N distinct node records and edges (matching the Python engine). Each invocation binds its `invocationID` on the `RTSNodeInvoker.currentInvocationID` `@TaskLocal` around its execution, so a child invocation reads it back as its edge `source` — propagating the parent link down through provider tool-calling code (Conduit's tool `TaskGroup`, Apple's `LanguageModelSession`) with no parameter threading. The instance `id` (`RTSNode.id`) is no longer used for tracing identity. See `docs/duplicate-node-id.md`.

**Events published unconditionally** — `RTSNodeInvoker` always publishes finish events — success or failure. Errors are captured in the event (`error: String?`) and re-thrown after publication. This ensures the JSON trace is complete even for failed runs.

**Gateway as the isolation boundary** — All Conduit and Apple Foundation Models–specific code is contained in `LLMGateway/`. Replacing the provider means re-implementing the `RTSLLMSession` builder and bridge, nothing more.

**Session-per-invocation** — Each agent invocation gets its own `RTSLLMSession` backed by a fresh provider session. Sessions are never shared across concurrent invocations, making `runID`-based message capture safe without locks.

**Collector finalizes on dual completion** — The collector tracks two independent completion signals: the root node's finish event and the root edge's finish event. Only when both have arrived does it write the JSON and tear down. This is reliable only because events are consumed in publish order (single ordered `AsyncStream`): the root's finish is published last, so it is processed after every descendant's events. A per-invocation in-process counter (node + edge) guards this — a non-zero value at finalization logs a warning, flagging any ordering violation.

### Guardrails

Per-agent input/output guardrails live in `Guardrails/` (abstraction + runner) and `Guardrails/Builtin/` (prebuilt ones). They run inside `RTSNodeInvoker.invokeAgent` (wrapping `invokeCore`) — the provider-agnostic seam — so they apply to every agent and sub-agent regardless of provider. Tools are unaffected.

- **Protocols** — `RTSAgentInputGuardrail` / `RTSAgentOutputGuardrail` (each requires `name` + async `check`), plus `RTSClosure{Input,Output}Guardrail` conformers. Results are two concrete enums (`RTSInputGuardrailResult` / `RTSOutputGuardrailResult`) with cases `.allowed` / `.blocked(reason:)` / `.transformed(_:)`, each carrying optional `metadata`; use the `.allow` / `.block` / `.transform` factories.
- **Runner** — `RTSGuardrailRunner` executes the chain in array order: `.transformed` feeds the next, the first `.blocked` yields `RTSError.guardrailBlocked`, and a thrown `check` is recorded as an `error` step and propagated (fail-closed/strict). It never throws — it returns `(value, traces, error?)`; the invoker re-throws the error.
- **Tracing** — verdicts become `RTSGuardrailTrace` values carried on `RTSNodeEvent.guardTraces` and serialized under `node.details.internals.guard_details`, matching the Python `GuardrailTrace` schema (`rail_name`/`phase`/`action`/`reason`/`meta`). Input guardrails run *before* the edge is published, so the edge's `input_kwargs` reflects the post-transform value (this diverges from Python, which records pre-transform — an open cross-team decision).
- **Prebuilt** — regex `RTSLength*`, `RTSBlockText*`, `RTSPIIRedact*` (ports of the Python guards), plus `RTSAppleAIPIIRedact*Guardrail`, a model-based PII redactor that calls FoundationModels **directly** (not via the gateway/flow) so raw pre-redaction text is never traced. AppleAI guards are `@available(macOS 26, iOS 26, *)`.

### Key types

- **`RTSValue`** — JSON-like enum (`null`, `bool`, `number`, `string`, `array`, `object`). `RTSInput` and `RTSOutput` are `[String: RTSValue]`. Has a custom `encode(to:)` that serializes as bare JSON primitives (not Swift's default tagged enum format).
- **`RTSAgentNode`** — protocol for LLM-backed nodes. Requires `tools`, `llmProvider`, and standard input keys (`prompt`, `systemMessage`). `RTSAgent` is the concrete implementation.
- **`RTSToolNode`** — protocol for function-backed nodes. Tools are registered on agents and invoked by the LLM via `RTSConduitToolBridge`, which adapts `RTSToolNode` to Conduit's `Tool` protocol. Set `isRequired = true` if schema conversion failure should be fatal rather than silently dropping the tool.
- **`RTSNodeInvoker`** — all node invocations must go through this. It generates stamps, publishes create/finish events for both nodes and edges, and handles id assignment. Each invocation gets a unique `runID` (message-tracing key; the root agent's `runID` doubles as the root edge ID) **and** a unique `invocationID` (the graph node identifier, per-invocation — see "Per-invocation node ids"). The parent's `invocationID` flows to children via the `currentInvocationID` `@TaskLocal` to form edge `source`s.
- **`RTSStamp`** — combines a monotonic step index (from `RTSStampFactory`) and a wall-clock timestamp. The step index provides deterministic ordering across concurrent events.
- **`RTSLLMGateway`** — instantiated with a provider+apiKey at the app level. Builds `RTSLLMSession` instances per agent invocation using `agentNode.llmProvider` to select the model.
- **`RTSLLMProvider`** — the provider choice, with Apple's two models as dedicated cases: `.appleAI` (on-device) and `.privateCloudCompute(options:)` (Apple's server model, OS 27). For both, the library builds the model itself (`AppleAISession`), so apps need no `#available` or FoundationModels import; `.foundationModel` is for third-party `LanguageModel`s. Two separate questions: `isLocal` is "runs on the device" (PCC is remote), and the internal `isBilled` is "priced in traces" (both Apple models are free to the developer) — pricing must use `isBilled`. Provider-only settings live in the case's associated value (`RTSGeminiOptions`, `RTSPrivateCloudComputeOptions`), so switching provider drops them. PCC's reasoning level becomes `ContextOptions` per `respond`; on structured output `includeSchemaInPrompt: true` must be kept, since passing any `ContextOptions` replaces Apple's default. PCC failures an app must act on become `RTSError.quotaLimitReached(provider:resetDate:)` and `RTSError.missingEntitlement(name:)`, mapped in `FoundationModelsErrorMapping` from the catch in `RTSLLMSession.build(appleAI:)` (the one place that knows the provider). The entitlement failure is an undocumented nested `NSError` (`ModelManagerServices.ModelManagerError` 1046, found by walking underlying errors) and PCC reports itself available without the entitlement, so the mapping is keyed on `provider.kind == .privateCloudCompute`, covering a PCC model wrapped in `.foundationModel` too. See `docs/private-cloud-compute.md`.

### JSON export

`RTSFlowGraph+Parser.swift` converts collected events into the JSON schema expected by the Python visualizer. Key structural points:
- Each `RTSFlowRun` has `nodes`, `edges`, and `steps` arrays.
- Nodes and edges each have a `parent` field (creation snapshot) and a finish-time entry (the main record). Creation snapshots always carry `"parent": null`.
- Several structs use custom `encode(to:)` to emit `null` for optional fields rather than omitting the key (required by the visualizer schema).
- `flow_id` is a SHA-256 hex hash of `flow_name`. `session_id` is a UUID generated per collector instance.
- `input_kwargs` values are encoded as bare JSON scalars via `RTSValue`'s custom encoder, not as typed wrapper objects.
- Run status reflects actual outcome: `.failed` if any edge event carries an error, `.completed` otherwise.

### Extension points

| Goal | What to implement |
|---|---|
| New LLM provider | New `RTSLLMSession.build` variant in `LLMGateway/` + bridge if tools needed |
| Third-party FoundationModels `LanguageModel` (e.g. Claude) | Nothing in the library — the app wraps it in `RTSFoundationLanguageModel` and uses `.foundationModel`. The library must **not** depend on a vendor package (it would force the package floor to OS 27). See `docs/foundation-models-provider.md`. Apple's own models are not this case: they have `.appleAI` and `.privateCloudCompute` |
| New tool | Conform to `RTSToolNode`; set `isRequired = true` if schema failure should be fatal |
| Structured output | Set `outputSchema` on the agent; conversion failure is always fatal by design |
| New guardrail | Conform to `RTSAgentInputGuardrail` / `RTSAgentOutputGuardrail` (or use the closure conformers); attach via `RTSAgent(inputGuardrails:outputGuardrails:)`. Prebuilt ones live in `Guardrails/Builtin/` |
| New RAG vector store | Conform to `RTSRAGVectorStore`, including `documents(under:scope:)` — the orphan sweep's listing; match scope exactly. See `docs/rag-orphan-sweep.md` |
| New RAG loader | Return an `RTSRAGDocumentStream`; pass `root:` (the path it was given) to opt in to the orphan sweep |
| Consume observability events | Subscribe to `RTSFlow.eventPublisher` — it's multicast, so add as many subscribers as you like. The one exception is a second `RTSEventWriter`: it would append to the same `<session id>.jsonl` as the flow's built-in writer. To own the file yourself, pass `savesEvents: false`; to observe it, read `flow.eventWriter` |

### Observability events

A second, independent output stream alongside the flow-graph JSON — a port of the Python engine's
event model (`node.*`, `session.*`, `llm.*`, `middleware.*`). `RTSEventEmitter` publishes envelopes
on `RTSFlow.eventPublisher`; `RTSEventWriter` appends them to `eventsOutputDirectory` as JSONL, one
object per line, `<session id>.jsonl`. That directory — like `flowGraphOutputDirectory` and
`evaluationOutputDirectory` — is derived and read-only; apps set only `RailtracksSwift.outputDirectory`,
and the `sessions` / `events` / `evaluations` subfolders beneath it are a library invariant.

`RTSFlow` builds and subscribes its own writer in `init`, gated on `savesEvents` — which defaults to
`nil`, meaning *follow `savesTrace`*. That inheritance is load-bearing, not cosmetic: `RTSJudgeEvaluator`
creates one flow per judge call (`metrics × datapoints × agents`), and it already passes
`savesTrace: false`, so event logs stay suppressed there without the evaluator knowing they exist.

The writer closes its file on each `session.completed` and re-arms, so repeated runs on one flow
append to a single file. `finish()` is terminal and is meant for app-owned writers only.

Design rationale, the Python mapping, and the verification runs live in `docs/observability-events.md`.

### RAG / retrieval (`RailtracksSwiftRAG`)

A separate target and library product at `Sources/RailtracksSwiftRAG/`, porting the Python engine's
`railtracks/retrieval`: loaders, chunkers, embedders and vector stores. Consumers opt in by
depending on the product — the SPM equivalent of Python's `pip install railtracks[retrieval]`.

**Types and files are prefixed `RTSRAG`.** `RAG` alone is too common a term to be collision-safe,
and `RTSRAG` stays accurate if the module is ever extracted, because the prefix tracks ownership
rather than repo location.

**The dependency rule, and it is checkable: the module depends on neither `RailtracksSwift` nor
Conduit.** Nothing in a retrieval pipeline needs agent orchestration — embedding is a pure
text-to-vector call, and even a semantic chunker splits on embedding distance rather than asking a
model. Python's `railtracks/retrieval` is standalone for the same reason. Conduit went the same
way in phase 4: its `embedBatch` issues one HTTP request per text and discards the response's
`usage` block, so `RTSRAGOpenAIEmbedding` calls `/v1/embeddings` directly instead — the array form
in one request, with the provider's own token count read back.

What remains is Foundation plus swift-log and swift-crypto, so extraction to another Apple platform
is moving the folder. Phase 6 put Combine in the public API (`RTSRAGRetrievalRuntime.eventPublisher`,
matching `RTSFlow`), so the module is now Apple-only in its *signature* rather than only in its
implementations — Linux is not a goal, but the distinction is worth knowing before anyone plans one.
Both of these must return **nothing**:

```bash
grep -rn "^import RailtracksSwift" Sources/RailtracksSwiftRAG/
grep -rn "^import Conduit" Sources/RailtracksSwiftRAG/
```

If a component ever genuinely needs an agent, add a bridge target depending on both rather than a
dependency here.

Apple's `NaturalLanguage` is the one platform framework the module's core pipeline leans on —
`NLTokenizer` for sentence boundaries and `NLContextualEmbedding` for on-device vectors — which
makes the default splitter and embedder Apple-only. Both sit behind protocols, so a Linux port
supplies different conformers rather than changing anything else. The `Spotlight/` folder (below)
adds Core Spotlight, and is Apple-only by nature.

`RTSRAGAppleEmbedding`'s assets may need an OS download, which reports no progress, cannot be
cancelled, and may never answer (in a Simulator, or on an offline device), and whose answer may
never come even when the model does arrive. So `prepare(timeout:)` bounds the wait (60 s by
default, `nil` for unbounded), checks `hasAvailableAssets` every 2 s while waiting, and throws
`RTSRAGError.embeddingModelNotReady` when the timeout passes, leaving the download running. Later
calls, from any embedder for that asset, join the same request (`RTSRAGAssetRequest`) for its first
30 s, then ask again. `loadIfAvailable()` never downloads, and
`assetsAvailable(revision:language:)` checks without loading. See `docs/apple-embedding-prepare.md`.

Chunk size is capped in **characters** (`RTSRAGLimits.defaultMaxChunkCharacters`), not tokens. A
chunker enforces that by construction, so oversized input is impossible rather than detected —
which is what lets the port ship without a token counter, since nothing in Swift can count OpenAI
tokens accurately (Conduit's `countTokens` is `text.count / 4`).

Design, the Python mapping, and the two deliberate departures from it live in `docs/rag-port.md`.

#### Spotlight path

A second ingest path, in `Spotlight/`, with Core Spotlight as both index and retriever and no vector
store of ours: `RTSRAGSpotlightIngestRuntime` runs loader → chunker → `RTSRAGSpotlightFeeder`, which
donates each chunk as a `CSSearchableItem`, and `RTSRAGSpotlightSearcher` queries it with
`CSUserQuery`. Spotlight embeds for itself, so there is no embedding step. It is kept as a separate
runtime rather than a generalised `RTSRAGRetrievalRuntime`, but shares that runtime's rules and types
(`RTSRAGIngestEvent`, `RTSRAGIngestionStats`). Every API it uses predates OS 27, so the package floor
is unchanged — `SpotlightSearchTool`, the one OS 27 API, was considered and not used.

- **Item ids are positional**, `"<documentID>#<chunkIndex>"` (`RTSRAGChunk.positionalIdentifier`),
  because `RTSRAGChunkID` is a random UUID per ingest. Each document is its own domain,
  `"<namespace>.<documentID>"`, and replacement is delete-the-domain then index — the delete is what
  clears trailing items when a document shrinks.
- **The staleness check asks Spotlight**, through custom attributes (source, content hash, chunk
  count, namespace), with no local ledger. Unlike the vector-store path, a failing staleness query
  re-donates rather than ending the run.
- **Items carry `expirationDate`** (`.distantFuture` by default); unset, Spotlight expires them
  silently.
- **Demo:** run it on `RailtracksSwiftDemoOS27`. Spotlight refuses the main target's bundle id with
  `CSIndexErrorDomain -1003`, persistently and for no stated reason.

Design, the chunk-to-item mapping, and the findings from real runs live in `docs/spotlight-rag.md`.

#### Orphan sweep

Both runtimes sweep after an ingest: **every stored document under the run's root that the run did
not see is removed.** Without it, a moved or renamed file left its old path's entries behind (every
passage retrieved twice) and a shrunk file kept its vanished pages or rows.

- **Root** is the file or folder the loader was pointed at, carried on `RTSRAGDocumentStream.root`.
  Built-in loaders set it; a custom loader's defaults to `nil`, which never sweeps.
- **Seen** is every id the run loaded, whatever became of it. Also kept: ids a `mapDocuments`
  transform dropped (so a sanitizer change is never destructive), and everything under a source
  that failed to load (unreadable is not gone). The stream records both.
- **No sweep** when the run threw or was cancelled, or with `ingest(…, sweepsOrphans: false)`. A
  failed sweep is counted in `sweepFailures`, never thrown.
- **The rule is one pure function**, `RTSRAGOrphanSweep.orphans(stored:seen:filtered:failedSources:)`,
  shared by both runtimes. Each runtime only lists what is stored under the root —
  `RTSRAGVectorStore.documents(under:scope:)` (scope matched **exactly**, unlike retrieval) or
  `RTSRAGSpotlightFeeder.documents(under:)` — and deletes what it returns.
- **Root matching** (`RTSRAGSourceRoot`): a source is under `R` when it equals `R` or starts with
  `R#` (a page or row) or `R/` (inside a folder). It matches every spelling of `R` — as given,
  canonical, and its `/private` counterpart — because `FileManager` enumerates `/var/…` as
  `/private/var/…`; without that, every folder sweep is a silent no-op.
- **Content hash is deliberately not used**: it cannot tell a move from a copy, and identical pages
  or rows are common.
- **A sweep reaches only its root.** A deleted or renamed sibling of a single picked file, or a
  renamed folder, is outside it — the app removes those with `removeSource(at:)`, on either runtime,
  which works on paths that no longer exist.

The rule, its use cases, and a possible injectable sweeper live in `docs/rag-orphan-sweep.md`.

### Concurrency model

The codebase targets Swift 6 strict concurrency. `RTSFlowGraphCollector` is an actor. `RTSNodeInvoker` is `@unchecked Sendable` (uses `PassthroughSubject` internally). `RTSLLMSession` is `Sendable` via closure capture. Combine sink closures always dispatch to actor methods via `Task { [weak self] in await self?.method() }`.

**Publishing must never run subscriber code on an invocation's thread.** `PassthroughSubject.send` delivers sinks synchronously on the caller's thread, so anything a subscriber does lands on the agent's critical path — and if the send is inside a lock (as `RTSNodeInvoker.lockedSend` still is), one slow subscriber blocks *every* node from publishing. The public streams are therefore isolated: `RTSEventEmitter` hands each envelope to a serial `DispatchQueue` that performs the send (no lock — the queue is the serialization), and `RTSFlow.nodeStatusPublisher` is `receive(on:)`-isolated. `RTSNodeInvoker`'s publishers stay synchronous because they are `internal` and both in-library subscribers do only bounded work (the collector yields into an `AsyncStream`; `RTSFlow` enqueues) — keep that invariant when adding one. Always a **serial** queue, never a `Task` per event: unordered dispatch is the race documented in `docs/duplicate-node-id.md`. The cost is asynchronous delivery, so `RTSFlow.run` joins the backlog on every exit path and `RTSFlow.flushEvents()` exposes the same barrier.
