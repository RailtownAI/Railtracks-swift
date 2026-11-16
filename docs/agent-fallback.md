# Agent fallback (#73)

**Status: design, on hold since 2026-11-16. Not implemented.**

## Where this stands (pick up here)

- **Phase 0, this doc, is drafted.** The decisions below were agreed with Mark:
  - fall back between whole agents, not models;
  - a specialised `RTSOrchestratorNode` named `RTSAgentFallbackNode`, agents only in v1;
  - the four-step policy;
  - the same-provider skip after `billing` and `authentication`;
  - the `unsupportedInput` reason.
- **Still to review with Mark** before phase 1:
  - the two invoker proposals (the fallback scope for `endOnError`, and `handledByFallback` for
    the run status);
  - the remaining open questions near the end of this doc.
- **Issue #73 is up to date.** Its body was rewritten around `RTSAgentFallbackNode`, with a
  "Decided" list, the two invoker changes and the open questions. A comment explains the move from
  "one agent, a list of providers" to "a list of agents", and why. This doc goes further than the
  issue on the policy: the four steps, the skip rule and `unsupportedInput` were decided after the
  issue was updated, so the issue needs a short follow-up when work resumes.
- **The Python ticket, railtracks#1788,** was still open and unassigned on 2026-11-16, with no
  comments and no linked PR. Raising the reason categories, the handled-failure rule and the
  run-status rule there is still to do.
- **#74 (image input) merged in PR #75.** Its vision refusal on `main` is still an
  `RTSError.invalidInvocation`, which phase 1 has to give its own signal (see the policy section).
- **This doc lives only in the local `docs/` folder, which isn't committed.** Issue #73 is the
  shared record.
- **Next step:** review the two invoker proposals and the open questions, then start phase 1 with
  tests first.

## Goal

When an agent's model call fails for a reason that says nothing about the request (out of credit,
rate limited, the provider down, Apple Intelligence unavailable), hand the same input to the next
agent in a priority list, usually the same agent built on another provider. The node fails, as
today, only when the list runs out or the error is one that should stop.

Today an app can only do this by catching the error around `flow.run` and running the whole flow
again. That throws away every node that already succeeded, and splits the attempts across
unrelated runs.

## Decision: a specialised orchestrator node, `RTSAgentFallbackNode`

Two shapes were considered:

1. **Fallback inside the agent.** The agent takes a list of providers and switches model
   mid-node.
2. **Fallback between agents.** A node calls each agent in turn, and each attempt is its own
   node.

**Chosen: 2.** The Python team treats a node's model as part of its identity, and their ticket
(railtracks#1788, a `Fallback` node middleware) routes between nodes, not models. Their working
sketch wraps the primary with `rt.wrap_node` and calls each backup with `rt.call`. In their test
run the primary failed, the first backup failed as its own node, the last backup succeeded, and the
session completed successfully. Their open questions overlap with ours:
- which errors trigger a fallback (an `on=` tuple, like `Retry`'s `retry_on`);
- tools re-running on the next attempt;
- backups accepting the same input;
- recursion when a backup carries the same `Fallback`;
- whether a shared `MaxCalls` budget covers every attempt. Parity here
means the same capability and observability output, not the same internal design, and option 2
gets both with no new event type:

- **Each attempt is a whole agent,** with its own system message, tools and guardrails. Prompts
  tuned for one model don't always suit another.
- **Each attempt has its own session,** so transcripts never mix across providers.
- **Each attempt is its own node,** with its own `node.*` and `llm.*` events, trace record, status
  and Instruments interval. A failed Gemini attempt followed by a successful Claude one is drawn
  as exactly that.
- **The run's timeout** already covers every node, so all attempts share one budget.

### Why an orchestrator node, not a new node kind

`RTSFunctionNode` has two refinements. `RTSToolNode` runs a closure and can't call other nodes.
`RTSOrchestratorNode` gets an `RTSRunContext`, whose `call` invokes an agent as its child. Fallback
needs to call agents as children, so it's an orchestrator. Building on that protocol, rather than
adding a node kind with its own invoker path, gives these for free:

- the parent edge and a fresh session per attempt (`RTSRunContext.call`);
- the node's lifecycle events, statuses, intervals, cancellation checks and timeout
  (`RTSNodeInvoker.invokeFunction`);
- use as a flow root (`flow.run(_:input:gateway:)`), and as a tool on another agent
  (`RTSOrchestratorTool`, with the Conduit and AppleAI bridges);
- a `function` node in the trace, which the Python visualizer and the Instruments kit already
  draw. A new node type would need changes in both of those repos.

The two problems below need the invoker's help whichever shape the node takes, so a new kind
wouldn't avoid them.

### Name and scope

`RTSAgentFallbackNode`, after `RTSAgentTool` and `RTSOrchestratorTool`: the behaviour, then the
kind. "Agent" is singular as a noun modifier ("agent fallback", as in "agent tool"); the plural is
implied by "fallback". `RTSFallbackNode` was rejected as too vague, and `RTSFallbackAgentsNode`
as awkward and out of line with the library's other names. **Agents only in v1.** The motivating failures are all about models, so the policy only has
to classify model errors, and every attempt has the same shape. A general node over agents and
orchestrators can sit beside it later.

## Proposed API

```swift
let gemini = RTSAgent(llmProvider: .gemini(modelIDString: "gemini-2.5-flash"), name: "Support")
let claude = RTSAgent(llmProvider: .anthropic(modelIDString: "claude-sonnet-4-6"), name: "Support")
let onDevice = RTSAgent(llmProvider: .appleAI, name: "Support")

let support = RTSAgentFallbackNode(
    name: "Support",
    agents: [gemini, claude, onDevice],     // priority order; the first is the primary
    policy: .default                        // which errors move on to the next agent
)

let output = try await flow.run(support, input: ["prompt": .string(question)], gateway: gateway)
```

- **`agents`:** at least one, in priority order. Built with fewer than two, the node is just a
  wrapper, which is allowed but logged.
- **Input:** each attempt gets the node's input merged over that agent's own `inputs`. That way
  each agent keeps its own system message unless the call sets one. `RTSRunContext.call(_:input:)`
  passes the input through unchanged, so the node does the merge.
- **Output:** the first successful agent's output, unchanged.
- **All attempts fail:** the node throws the last attempt's error, as Python's sketch raises
  `last_error`. Each earlier error is already on its own attempt's node in the trace.

### The policy

Each time an attempt fails, the node runs four steps, always in this order:

1. **Hard stops (library, can't be overridden).** If the error is one, the node fails with it,
   and the policy is never asked.
2. **Classification (library).** The error is mapped to an `RTSFallbackReason`, or `nil` when it
   isn't about the provider or is unknown. This step decides nothing. It only fills in the
   reason the policy is given.
3. **The policy (app).** It says whether to fall back. This is the only place the app decides,
   and it can't override step 1.
4. **The next agent (library).** After a yes, the node picks the next agent in the list. After
   `billing` or `authentication`, it skips the remaining agents on the same provider
   (`llmProvider.kind`), since out of credit or a bad key on Gemini fails every Gemini model.
   Each skip is logged. If no agent is left, the node fails with the error that triggered the
   fallback.

`invokeCore`'s fallback scope (problem 1 below) uses this same function, so a failure counts as
handled exactly when step 3 says yes **and** step 4 finds an agent.

```swift
public struct RTSFallbackPolicy: Sendable {
    /// Falls back when the failure's reason is in `reasons`. An unknown error (`reason == nil`)
    /// never falls back.
    public init(reasons: Set<RTSFallbackReason>)
    /// Full control, for errors the reasons don't cover, such as a custom provider's error.
    public init(_ fallsBack: @escaping @Sendable (RTSFallbackFailure) -> Bool)

    public static let `default`: RTSFallbackPolicy
}

/// What the policy is given about one failed attempt.
public struct RTSFallbackFailure: Sendable {
    public let error: any Error
    public let reason: RTSFallbackReason?   // step 2's answer
    public let failedAgent: any RTSAgentNode
    public let attempt: Int                 // 0 for the primary
}

public enum RTSFallbackReason: Sendable, Hashable {
    case billing              // out of credit or quota
    case rateLimited
    case serverError          // 5xx
    case network
    case providerUnavailable  // provider or model unavailable, including Apple Intelligence
    case timeout              // the provider's own timeout, not the run's
    case authentication
    case unsupportedInput     // the model can't take this input, e.g. an image on a model without vision

    /// Step 2. Public, so a custom predicate can reuse the mapping.
    public static func of(_ error: any Error) -> RTSFallbackReason?
}
```

- **A struct holding one closure,** not a protocol. Both initializers reduce to the same closure,
  and the policy holds no state.
- **The predicate is given `RTSFallbackFailure`, not just the error.** With the failed agent and
  the attempt number it can express rules such as "only fall back from the primary" without new
  API.

The library classifies an error into a reason once. That spares apps from matching Conduit's
`AIError` / `CloudError`, FoundationModels' `GenerationError` / `LanguageModelError` and
`RTSError` themselves. It unwraps `AIError.cloudError` and one level of
`AIError.generationFailed(underlying:)`, where transport errors can arrive wrapped:

| Reason | Conduit (`AIError`, and `CloudError` through `.cloudError`) | FoundationModels |
|---|---|---|
| `billing` | `billingError` | — |
| `rateLimited` | `rateLimited` | `GenerationError.rateLimited`, `.concurrentRequests`; `LanguageModelError.rateLimited` |
| `serverError` | `serverError` with status ≥ 500 | — |
| `network` | `networkError` | — |
| `providerUnavailable` | `providerUnavailable`, `modelNotFound` | `GenerationError.assetsUnavailable`; `SystemLanguageModel` unavailable |
| `timeout` | `timeout` | `LanguageModelError.timeout` |
| `authentication` | `authenticationFailed` | — |
| `unsupportedInput` | — | `LanguageModelError.unsupportedCapability`, `.unsupportedTranscriptContent` |

Also from `RTSError`:
- `providerUnavailable` (`.appleAI` below OS 26, `.foundationModel` below OS 27) is
  `providerUnavailable`;
- `missingAPIKey` is `authentication`;
- the image-input refusal from #74 (a model without vision) is `unsupportedInput`.

**Dependency on #74:** that refusal is currently an `RTSError.invalidInvocation`, which is a hard
stop below. It needs its own signal, such as a dedicated `RTSError` case, so the classifier can
recognise it without parsing message text. Then `invalidInvocation` stays a hard stop for genuine
misuse.

**`.default`** is every reason except `authentication`. A bad key is a configuration bug that
falling back would hide. The issue and Python's ticket both lean towards excluding it.
`unsupportedInput` is in the default: a model that can't take the input is a limitation of that
model, not a fault in the request.

**Never falls back, whatever the policy:**
- **`RTSError.runTerminated`:** cancellation, the timeout and `endOnError`. A stop must not start
  another attempt, the same rule as "a `runTerminated` never triggers `endOnError`".
- **Errors that would fail any model the same way:** `guardrailBlocked`, `invalidSchema`,
  `missingInput` and `invalidInvocation`. A predicate can't opt into these either.

**Note:** Conduit's `isRetryable` isn't used. It means "retrying the same model may work", so it
marks `billingError` not retryable, and billing is the main reason to fall back.

## The two problems

### 1. A handled failure must not trigger `endOnError`

`invokeCore` calls `runStop.nodeFailed` once a node's outcome is final. With `endOnError`, that
stops the run. A Gemini attempt failing on billing would end the run before Claude was tried.

**Proposal: a fallback scope, carried as a task-local.**
- The node binds `RTSNodeInvoker.currentFallbackScope` around each attempt except the last. The
  scope holds the policy and the node's own invocation id.
- `invokeCore` reads the scope **only when the invocation's parent is that id**, meaning the
  attempt agent itself. A tool or sub-agent deeper inside the attempt never sees it. Task-locals
  reach every descendant, so without the check a sub-agent's failure inside an attempt would be
  wrongly treated as handled.
- When the scope applies and the policy accepts the error, `invokeCore` skips
  `runStop.nodeFailed`, and marks the node's `node.destruction` as handled (below).
- The last attempt runs with no scope, so its failure fails the node and triggers `endOnError` as
  today. So does an error the policy rejects, at any attempt.

### 2. A recovered run must not be marked failed

The trace marks a run failed if any edge carries an error (`RTSFlowGraph+Parser`:
`edgeEvents.contains { $0.error != nil }`). A run that recovered through fallback would still
read as failed. Python's sketch reports the session completed.

**Proposal:** `node.destruction` gets an internal `handledByFallback` flag, off the wire like
`terminationReason`. The failed attempt's edge keeps its error and its Python
`Failure.encode` output, so the visualizer's error panel still shows what failed. The run status
ignores handled edges.

`session.completed`'s `fatal` and `termination_reason` already come from the run's own error,
which a recovered run doesn't have, so they need no change.

## Observability

```
Support  (function, RTSAgentFallbackNode)
├── Support  (agent, Gemini)   ✗ billing error, handled
└── Support  (agent, Claude)   ✓
```

- **Events:** unchanged, one lifecycle per attempt. The fallback node's own `node.*` lifecycle
  wraps them.
- **Trace:** a `function` node with one child edge per attempt. The run is `Completed` if an
  attempt succeeded.
- **Statuses:** a failed attempt is `.failed`, which is accurate: that node did fail. The fallback
  node is `.completed`. No new state.
- **Instruments:** one Node Runs interval per attempt, nested under the fallback node's.
- **Logs:** each fallback logs `🔁 [<node>] <agent> (<model>) failed with <reason>; trying <next>`.

**How this differs from Python.** Python attaches `Fallback` as middleware on the primary agent.
Swift has no node middleware yet (#63), so here the fallback node is the parent of the attempts.
Both show each attempt as its own node, with its own failure or result. If #63 lands, a middleware
form can be added that reuses the same policy and scope.

## Open questions

- **Side effects before the failure.** A failure can come after tools have already run, and the
  next agent starts from the original input, so those tools run again. Options: document it (as
  Python plans to), or add an option to fall back only when no tool ran yet. That would need the
  node to know whether its attempt ran any tool.
- **`rateLimited(retryAfter:)`.** v1 moves straight to the next agent. The next one is usually
  another provider, so waiting would only add latency. Revisit if same-provider fallbacks become
  common.
- **Error when all attempts fail.** Rethrowing the last error matches Python. An
  `RTSError.allAttemptsFailed([Error])` would carry every error. But a new case is a source break
  for exhaustive switches, and the trace already has each error on its own node.
- **Convenience entry points.** `flow.run(agent:prompt:)` takes an `RTSAgentNode`, which the
  fallback node isn't. A `flow.run(_ node: RTSAgentFallbackNode, prompt:)` returning the text, and
  an `asTool(description:)` that builds the `RTSOrchestratorTool` with the agent's prompt schema,
  would keep it as easy to use as an agent.
- **Input compatibility.** Python suggests checking that backups accept the same input. Every
  agent takes `prompt` / `systemMessage` / `images`, so this matters only once agents with custom
  input keys exist.
- **Python alignment.** Share the reason categories, the handled-failure rule and the run-status
  rule with the Python team on railtracks#1788, which is still unassigned, so both engines report a
  recovered run the same way.

## Plan

Each phase starts with tests, ends with `swift build && swift test`, and pauses for review and
commit.

0. **This doc.** Agree the API, the default policy and the two proposals.
1. **The policy:** `RTSFallbackReason`, `RTSFallbackPolicy`, the classifier and the four-step
   decision. It's pure, so it's tested with constructed errors from Conduit, FoundationModels and
   `RTSError`:
   - each row of the mapping table, the unwrapping, and an unknown error giving `nil`;
   - the hard stops winning over a predicate that always says yes;
   - the same-provider skip after `billing` and `authentication`, but not after `rateLimited`;
   - a skip that leaves no agent failing with the triggering error.

   This phase also adds the dedicated signal for #74's image-input refusal.
2. **The node:** `RTSAgentFallbackNode`. Tests with scripted sessions (`ScriptedFlowSupport`):
   - the first agent succeeds, so there's no fallback;
   - billing then success;
   - a rejected error stops at once;
   - `runTerminated` never falls back;
   - every attempt failing rethrows the last error;
   - input merging keeps each agent's system message.
3. **The invoker:** the fallback scope and `handledByFallback`. Tests:
   - with `endOnError`, a handled attempt doesn't stop the run, but the last attempt's failure does;
   - a sub-agent's failure inside an attempt isn't treated as handled;
   - a recovered run's trace status is `Completed`.
4. **Observability goldens:** a fallback run in `TraceGoldenTests` (trace, events, statuses,
   intervals).
5. **Demo and docs:** a demo that falls back from a deliberately bad key to a working provider, the
   README, and AGENTS.md (Extension points, the run-status rule).
