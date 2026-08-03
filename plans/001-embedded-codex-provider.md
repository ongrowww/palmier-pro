# Plan 001: Add a feature-complete embedded Codex provider

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. Commit your work in the isolated worktree. One
> override for an improve-skill dispatch: do not update `plans/README.md`;
> the reviewer maintains the index.
>
> **Drift check (run first)**:
> `git diff --stat 118fe1c..HEAD -- Sources/PalmierPro/Agent Sources/PalmierPro/Settings/AgentPane.swift Sources/PalmierPro/App/AppDelegate.swift Tests/PalmierProTests/Agent`
>
> If an in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. A semantic
> mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `118fe1c`, 2026-07-30

### Completion note

Completed in commit `a949e9c` and subsequently merged through the
`ongrow/codex-provider` integration branch into `main`. GitHub CI, the complete
Swift test suite, and ad-hoc DMG packaging passed. Later upstream syncs retained
the provider implementation and its tests.

### Execution note

Initial local execution on 2026-07-30 stopped at the Step 1 verification gate. The selected
developer directory was `/Library/Developer/CommandLineTools` and no full
`Xcode.app` was installed. `swift test --filter CodexSession` first failed
because the Metal build plugin could not find `metal`; retrying with the
repository-documented `PALMIER_SKIP_METAL_PLUGIN=1` bypass then failed before
Palmier source compilation because `SwiftUIMacros.EntryMacro` was unavailable.
The user selected a CI-first continuation: implementation proceeded on the
isolated `ongrow/codex-provider` branch, GitHub `ci.yml` on `macos-26` became the
authoritative build/test gate, and `byok-preview.yml` produced the installable
DMG. The implementation passed those gates and was merged into `main`.

## Why this matters

Palmier's top-left chat currently supports only Palmier Cloud or a directly
configured Anthropic API key. The user needs Codex as a first-class in-app
provider: authenticated through the installed Codex CLI, with persistent
threads, streaming, dynamically discovered models, model-specific reasoning
levels, normal/fast service tiers, cancellation, visible tool activity, and
safe approval handling.

The implementation must establish a provider boundary that a later Claude Code
adapter can reuse. It must not fork Palmier's editing logic. Codex must receive
the existing Palmier instructions, skills, and tool schemas and route dynamic
tool calls back into the project window's existing `ToolExecutor`.

## Product decisions

These decisions are part of the requested feature and are not left to the
executor:

1. The existing chat button and panel remain the entry point.
2. Provider, model, reasoning, and speed controls live in the bottom bar of the
   prompt box, where Palmier currently shows the Anthropic model and BYOK
   indicator.
3. A chat session is bound to one provider. The provider may be changed only
   while that session has no messages. Model, reasoning, and speed may change
   between turns when the provider advertises support.
4. The first provider choices are `Palmier` and `Codex`. `Palmier` preserves the
   current Cloud/BYOK selection behavior. Do not add a nonfunctional Claude
   choice; Claude Code is the next provider built on the resulting abstraction.
5. Codex models, reasoning efforts, and service tiers are loaded from
   app-server `model/list`. Do not hardcode model IDs or assume that
   `gpt-5.6-sol` exists on another account or future CLI.
6. The installed Codex CLI and its existing authentication are used. No OpenAI
   API-key field is added to Palmier and no credential is read or copied.
7. Palmier tools are registered as Codex app-server `dynamicTools` and executed
   directly through `ToolExecutor`. The embedded provider does not depend on
   Palmier's localhost MCP server being enabled.
8. Codex receives `ToolDefinitions.inAppAgent`, including `read_skill`, plus
   `AgentInstructions.serverInstructions` and the current
   `AgentInstructions.skillsSection(...)`. It must therefore have parity with
   the existing in-app agent rather than the external MCP session.
9. Built-in Codex command/file actions remain sandboxed and require app-server
   approvals. Never launch with a bypass-approvals or danger-full-access flag.
10. Approval cards offer deny and one-time approval. Add "allow for session"
    only where the protocol explicitly supports it. Deny is the safe default
    when a request is cancelled, its chat closes, the project closes, or the
    child process exits.
11. Codex process and JSON parsing never run on the main actor. UI state and
    `ToolExecutor` remain main-actor owned.
12. Raw prompts, tool arguments/results, approval payloads, auth state, and
    environment values must not be written to logs or analytics.
13. Existing chat JSON must decode without migration work by the user.
    Provider-specific fields are additive and use `decodeIfPresent`.

## Current state

### Repository and verification

- Swift 6.2 executable package, SwiftUI/AppKit, macOS 26, arm64.
- Source target: `Sources/PalmierPro`.
- Tests use Swift Testing in `Tests/PalmierProTests`.
- Required broad verification is `swift build` and `swift test`.
- The repository requires focused commit messages such as
  `[agent] Add embedded Codex provider`.
- `AGENTS.md` requires one state owner, thin SwiftUI views, explicit
  cancellation, no blocking work on `@MainActor`, shared domain operations,
  and an end-to-end check for Agent/MCP behavior.

### Existing provider selection

`Sources/PalmierPro/Agent/AgentService.swift:39-75` currently couples provider
and model selection to Anthropic:

```swift
var canStream: Bool {
    if hasApiKey { return true }
    let account = AccountService.shared
    return account.isSignedIn && account.hasCredits
}

private func selectClient() -> (any AgentClient)? {
    let chosen = effectiveModel
    if hasApiKey { return AnthropicClient(apiKey: apiKey, model: chosen) }
    if AccountService.shared.isSignedIn {
        return PalmierClient(model: chosen)
    }
    return nil
}
```

The existing `AgentClient` protocol in
`Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift:70-76` is an
Anthropic-wire abstraction:

```swift
protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
}
```

Do not force Codex JSON-RPC events through `AnthropicStreamEvent`. Introduce a
higher-level provider/runtime boundary and keep the two existing
Anthropic-compatible clients behind a Palmier-provider adapter.

### Existing turn/tool loop

`Sources/PalmierPro/Agent/AgentService.swift:355-397` owns chat state, creates
the authoritative tool schemas, runs tools, and loops after Anthropic
`tool_use`:

```swift
await SkillStore.shared.reloadInBackground()
let tools = ToolDefinitions.inAppAgent.map {
    AnthropicToolSchema(
        name: $0.name.rawValue,
        description: $0.description,
        inputSchema: $0.inputSchema
    )
}
```

`Sources/PalmierPro/Agent/Tools/ToolExecutor.swift:6-60` states that the same
executor is shared by MCP and the in-app agent. Preserve this single source of
truth. Codex dynamic calls must invoke:

```swift
await toolExecutor.execute(name: name, args: args, source: "codex")
```

Do not use the external-session `manage_project` tool. The in-app
`ToolExecutor(editor:)` is already bound to its project window.

### Existing skills

`Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:1057-1096` defines
`read_skill` as in-app only and includes it in
`ToolDefinitions.inAppAgent`. `AgentInstructions.skillsSection` adds the
one-line skill index to the system instructions. Codex dynamic tools must use
this same list. Do not change the external MCP contract as part of this plan.

### Existing session persistence

`Sources/PalmierPro/Agent/ChatSessionStore.swift:3-27` currently persists:

```swift
struct ChatSession: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [AgentMessage]
    var isOpen: Bool
}
```

`VideoProject.captureSaveSnapshot()` serializes every nonempty chat session
into the `.palmier/chat` directory. Extend `ChatSession` additively with its
provider, Codex thread ID, selected model, reasoning effort, and service tier.
Legacy files must default to the Palmier provider.

### Existing UI

`Sources/PalmierPro/Agent/Panel/AgentPanelView.swift:140-168` has a compact
Anthropic model picker and BYOK label. `AgentInputBox` supplies a generic
`leadingTools` slot in its bottom bar. Replace the current narrow pair with a
provider-capability control group; do not redesign the input box.

Match `AppTheme`, `.menuStyle(.borderlessButton)`, `.menuIndicator(.hidden)`,
`.fixedSize()`, existing font sizes, and existing help labels. Provider/model
changes are high-frequency controls: use no staged or decorative animation.
Use state label/icon/color together; motion must not be the only signal.

`AgentMessageView` already renders `toolUse` and `toolResult` blocks using
`ToolRunRow`. Reuse these blocks for Codex dynamic Palmier tools. Add a
separate compact approval row/card only for pending Codex approvals; do not
serialize transient approval requests into project chat history.

### Codex app-server facts verified on the planning machine

- Executable: `/Users/schrobo/.local/bin/codex`
- Version at planning time: `codex-cli 0.145.0`
- Transport: `codex app-server --stdio`
- Protocol: newline-delimited JSON-RPC 2.0.
- Required startup: `initialize` request followed by `initialized`
  notification.
- `model/list` returns model IDs, display names, default reasoning effort,
  supported reasoning efforts, default service tier, and supported service
  tiers.
- On the planning account, the catalog included `gpt-5.6-sol`, but this is
  evidence for dynamic discovery, not permission to hardcode it.
- `thread/start` accepts `cwd`, `model`, `approvalPolicy`, `sandbox`,
  `developerInstructions`, `dynamicTools`, `serviceTier`, and persistence
  controls.
- `turn/start` accepts `threadId`, input items, `model`, `effort`,
  `serviceTier`, and approval policy.
- `agentMessage/delta` streams assistant text.
- `item/started` and `item/completed` carry dynamic-tool and other activity.
- `turn/completed` is the terminal success/error notification.
- `turn/interrupt` cancels an active turn.
- `item/tool/call` is a server request containing `callId`, tool name,
  arbitrary JSON arguments, thread ID, and turn ID. The response contains
  `success` and `contentItems`.
- Command, file-change, permission, and MCP elicitation requests are
  server-to-client approval requests that require a correlated response.
- `account/read` provides non-secret login status.

The app-server protocol is versioned but currently marked experimental.
Decode only the fields Palmier uses, ignore unknown object fields and
notification methods, and surface a clear compatibility error instead of
crashing when a required method or field is unavailable.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Drift | `git diff --stat 118fe1c..HEAD -- Sources/PalmierPro/Agent Sources/PalmierPro/Settings/AgentPane.swift Sources/PalmierPro/App/AppDelegate.swift Tests/PalmierProTests/Agent` | no semantic drift before edits |
| Focused protocol/session tests | `swift test --filter Codex` locally when full Xcode is available | all Codex tests pass |
| Existing Agent regression tests | `swift test --filter Agent` locally when full Xcode is available | all selected tests pass |
| CI build and full suite | `gh workflow run ci.yml --ref ongrow/codex-provider` followed by `gh run watch <run-id> --exit-status` | GitHub `Build & Test` passes |
| Preview package | push `ongrow/codex-provider`, then watch `byok-preview.yml` | ad-hoc DMG artifact uploaded |
| Scope | `git status --short` | only plan in-scope files changed |

Do not invoke a paid Codex turn in automated tests. Protocol integration tests
must use a fake app-server subprocess/transport or a checked-in test fixture.
A manual live smoke test may use the real installed CLI only after the
operator explicitly approves possible model usage.

When full local Xcode is unavailable, commit only coherent reviewable slices
to `ongrow/codex-provider`, push them, and use GitHub CI logs as the compiler
and test feedback loop. Do not merge into the BYOK branch until CI is green.

## Suggested executor toolkit

- Follow `AGENTS.md` before editing.
- Reuse `AppTheme`; do not introduce a UI dependency.
- If available, use the `better-ui` skill only to review the compact provider
  controls and approval card against Palmier's existing density and motion.
- Generate a temporary app-server schema while developing with:
  `codex app-server generate-json-schema --experimental --out <temporary-dir>`.
  Never commit the generated schema bundle.

## Scope

**In scope** (the only source/test areas that may be modified):

- `Sources/PalmierPro/Agent/AgentService.swift`
- `Sources/PalmierPro/Agent/ChatSessionStore.swift`
- `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift`
- `Sources/PalmierPro/Agent/Clients/AnthropicClient.swift` only if required to
  conform to the provider boundary
- `Sources/PalmierPro/Agent/Clients/PalmierClient.swift` only if required to
  conform to the provider boundary
- `Sources/PalmierPro/Agent/Providers/` (create; provider-neutral types and
  Palmier adapter)
- `Sources/PalmierPro/Agent/Codex/` (create; executable discovery, JSON-RPC
  protocol, process transport, and Codex provider)
- `Sources/PalmierPro/Agent/Panel/AgentPanelView.swift`
- `Sources/PalmierPro/Agent/Panel/AgentMessageView.swift`
- `Sources/PalmierPro/Agent/Panel/AgentApprovalView.swift` (create if useful)
- `Sources/PalmierPro/Settings/AgentPane.swift`
- `Sources/PalmierPro/App/AppDelegate.swift`
- `Tests/PalmierProTests/Agent/Codex*.swift` (create)
- Existing Agent tests only where additive session-decoding assertions belong
- `README.md` for a concise Codex requirement/behavior note

**Out of scope**:

- Claude Code implementation or disabled Claude UI
- FAL generation behavior, catalogs, pricing, or confirmation logic
- External MCP HTTP routing and `manage_project`
- Copying Palmier skills into `~/.codex/skills`
- Modifying `~/.codex`, Codex configuration, Codex authentication, Keychain,
  or any credential file
- Bundling or automatically installing the Codex binary
- Disabling SIP, Gatekeeper, sandboxing, or approval checks
- CI/signing/notarization changes
- Broad chat visual redesign
- Logging raw model, user, project, media, tool, or approval payload content

## Git workflow

- Work only in the isolated executor worktree.
- Use one or more focused commits with the repository style. Final logical
  commit title: `[agent] Add embedded Codex provider`.
- Do not push, merge, or edit the user's branch.
- Do not update `plans/README.md`; the reviewer owns plan status.

## Architecture to implement

### Provider-neutral layer

Create a small provider abstraction owned by `AgentService`, not by SwiftUI.
Exact names may follow Swift API guidelines, but the layer must represent:

- provider identity (`palmier`, `codex`);
- provider availability (`available`, `missing executable`, `signed out`,
  `incompatible`, `failed`);
- catalog models with display name, supported/default reasoning effort, and
  supported/default service tier;
- selected provider/model/reasoning/tier per `ChatSession`;
- turn events: assistant text delta, Palmier tool started/completed, approval
  requested/resolved, terminal completion, and provider error;
- external conversation/thread ID;
- cancellation and approval response.

The abstraction must not expose `AnthropicMessage`, Codex JSON dictionaries,
`Process`, `Pipe`, or SwiftUI bindings. Existing Palmier/Anthropic clients may
remain wire-level clients behind `PalmierAgentProvider`.

### Codex process and JSON-RPC

Use an actor for the shared child process and pending JSON-RPC requests.

Required invariants:

- one app-server process per Palmier app process;
- multiple Palmier chat sessions map to independent Codex thread IDs;
- request IDs are unique and pending continuations are completed exactly once;
- stdout is incrementally buffered by newline and decoded off-main;
- malformed lines produce a bounded compatibility diagnostic, never a crash;
- stderr is drained to prevent child-process blocking, retained only in a
  small bounded diagnostic tail, and never telemetry-uploaded;
- unexpected termination fails all pending requests/turns and changes provider
  availability;
- cancellation sends `turn/interrupt`; closing a session cannot accidentally
  interrupt another thread;
- shutdown terminates the child and resolves all continuations;
- no `readDataToEndOfFile`, semaphore wait, or blocking `waitUntilExit` on the
  main actor.

Resolve the executable without a shell. Search in this order:

1. a user-selected executable URL stored as a non-secret bookmark/path;
2. process `PATH` entries;
3. `~/.local/bin/codex`;
4. `/opt/homebrew/bin/codex`;
5. `/usr/local/bin/codex`.

Validate that the URL is a regular executable file. Never interpolate paths
into a shell command. Launch `Process.executableURL` directly.

Build an explicit allowlist environment rather than blindly copying the whole
Palmier environment. Preserve only values required for normal CLI operation,
such as `HOME`, `PATH`, `TMPDIR`, locale, and an explicitly present
`CODEX_HOME`. Do not forward unrelated API keys or tokens.

### Codex thread configuration

On the first turn for a Codex chat:

1. Ensure app-server is initialized and account status is usable.
2. Reload Palmier `SkillStore` off the UI critical path.
3. Build `dynamicTools` from `ToolDefinitions.inAppAgent`.
4. Build developer instructions from
   `AgentInstructions.serverInstructions`,
   `AgentInstructions.skillsSection(SkillStore.shared.skillIndex)`, and a
   concise statement that the conversation is bound to the currently open
   Palmier project and should use provided Palmier tools for edits.
5. Start a persistent Codex thread and save its returned opaque thread ID in
   `ChatSession`.
6. Use a safe sandbox and approval policy. Do not use danger-full-access or
   approval bypass.

For later turns, resume/use that exact thread ID. If app-server reports the
thread is missing after Codex local state was cleared, show a recoverable
message offering to start a new Codex chat. Do not silently create a new thread
under an old visible transcript.

### Dynamic Palmier tools

For every `item/tool/call`:

1. Validate that the requested name exists in
   `ToolDefinitions.inAppAgent`; reject anything else.
2. Require arguments to be a JSON object and bridge it to `[String: Any]`
   without lossy string construction.
3. Emit a unified tool-start event so existing `ToolRunRow` renders it.
4. Execute through the current session's `ToolExecutor` with source `codex`.
5. Convert `ToolResult.Block.text` to app-server `inputText`.
6. Convert `ToolResult.Block.image` to a `data:<mime>;base64,...` app-server
   `inputImage` item.
7. Return `success: !result.isError`.
8. Emit the unified tool-complete event and persist the same tool/result blocks
   already used by Palmier chat.

Tool calls are scoped by both thread ID and active turn ID. A call from another
project/session must never reach this `AgentService`'s executor.

### User input and mentions

Preserve current mention behavior:

- Always send the user's visible text.
- Prepend the existing structured context hint for media, clip, and timeline
  range mentions.
- For referenced image assets supported by the selected model, add app-server
  local-image input items using validated absolute paths.
- For unsupported modalities, keep the textual context and add a concise
  nonfatal note; do not drop the entire turn.
- Never inline multi-megabyte base64 images into JSON-RPC when app-server
  accepts a local path.

### Approvals

Represent pending approvals as transient provider state keyed by JSON-RPC
request ID, thread ID, and turn ID. The UI must show:

- action kind (command, file change, permission, or MCP elicitation);
- a concise sanitized summary;
- optional protocol-provided reason;
- Deny and Allow once;
- Allow for session only if the response enum explicitly supports it.

Do not show secrets or entire environment blocks. Long commands/paths are
line-limited with an expandable detail area. Escape denies the pending request.
Cancelling the turn denies unresolved requests before interrupting it.

While an approval is pending, the transcript remains interactive for its
approval controls but the normal Send button is disabled. Approval responses
must be correlated and completed exactly once.

### UI behavior

Use a compact bottom-bar control group:

- Provider menu: Palmier / Codex.
- Model menu: shown when the provider exposes models.
- Reasoning menu: shown only when the chosen model offers more than one value.
- Speed menu: `Normal` plus each advertised service tier, using the advertised
  display name (for example `Fast`) and help description.
- A short status label for `Codex not installed`, `Sign in to Codex`, or
  incompatible CLI. Provide `Open Settings` where actionable.

Do not hardcode a "Fast" switch when `serviceTiers` is empty. Do not present a
reasoning value unsupported by the selected model. When the model changes,
retain the current reasoning/tier only if supported; otherwise select the
model's advertised default.

The provider selector is disabled after the session has messages and explains
via `.help` that a new chat is needed to change provider. Model/reasoning/tier
remain selectable between turns and are disabled during an active turn.

The controls must preserve Palmier's current density and `AppTheme`. Avoid a
large settings form inside the chat. There must be keyboard focus and help
labels for menus and approval buttons, and the approval state must not rely
only on color or animation.

### Settings

Extend `AgentPane` with a Codex section that:

- reports Installed / Not found / Signed out / Incompatible without exposing
  account tokens;
- shows the resolved executable path;
- lets the user select a different `codex` executable with `NSOpenPanel`;
- lets the user clear that override and return to automatic detection;
- offers an external action to open Terminal or Codex login instructions when
  signed out, without collecting credentials in Palmier.

Executable discovery and account probing must be asynchronous and must not
block the Settings view's main actor.

### Lifecycle

Before Palmier finishes application termination, asynchronously shut down the
Codex app-server process after active agent turns are cancelled. Do not make
project saving depend on a model response. If clean shutdown takes too long,
terminate the child and allow Palmier termination to continue.

## Steps

### Step 1: Add provider-neutral value types and persistence

Create the provider identity, availability, catalog, selection, turn event,
approval, and runtime protocol types under
`Sources/PalmierPro/Agent/Providers/`.

Extend `ChatSession` with additive provider metadata and custom decoding
defaults. Add tests covering:

- decoding a legacy session JSON with no provider fields;
- round-tripping a Codex session with thread/model/reasoning/tier;
- provider switching allowed only for an empty session;
- selection normalization when a catalog drops an effort or tier.

**Verify**: run `swift test --filter CodexSession` locally when full Xcode is
available; otherwise push the coherent slice and require the GitHub `Build &
Test` job to pass before treating the step as verified.

### Step 2: Implement and unit-test the JSON-RPC process transport

Create the executable locator and actor-based app-server transport. Separate
pure JSON-RPC encoding/decoding/routing from the real `Process` wrapper so tests
can inject a fake line transport.

Test:

- initialize ordering;
- concurrent request ID correlation and out-of-order responses;
- unknown notifications ignored;
- server requests routed and replied once;
- split stdout chunks and multiple JSON lines per chunk;
- malformed line behavior;
- cancellation;
- child termination failing pending requests;
- bounded stderr diagnostics;
- environment allowlist excludes a representative secret variable;
- executable resolution order.

No test may read Codex auth/config files or invoke a paid turn.

**Verify**: `swift test --filter CodexAppServer` locally when available;
otherwise the GitHub `Build & Test` job must pass.

### Step 3: Implement the Codex provider and dynamic-tool bridge

Implement initialization, `account/read`, paginated `model/list`,
`thread/start`, `turn/start`, text deltas, dynamic tool calls, tool results,
terminal completion/errors, cancellation, and approval response routing.

Use dependency injection for app-server transport and tool execution so tests
can simulate an entire turn:

1. initialize;
2. discover catalog;
3. start thread with Palmier instructions and dynamic tools;
4. start turn with mention context;
5. receive assistant delta;
6. receive a dynamic Palmier tool call;
7. return success/error content;
8. receive more text;
9. complete.

Add negative tests for unknown tool, non-object arguments, wrong thread/turn
routing, unavailable account, missing restored thread, process death, and
interrupt during a pending approval.

**Verify**: `swift test --filter CodexProvider` locally when available;
otherwise the GitHub `Build & Test` job must pass.

### Step 4: Refactor AgentService behind the provider boundary

Keep `AgentService` as the sole UI/chat state owner. Adapt the existing
Palmier/Anthropic run loop to the new provider-neutral interface without
changing current Cloud/BYOK behavior.

Wire Codex events into existing `AgentMessage` text/tool blocks, session
persistence, stream state, errors, analytics-safe provider identity, and
cancellation. Ensure selecting another tab cannot route Codex events or tools
into the newly selected session.

Do not capture raw prompts or arguments in analytics. Add tests using fake
providers for stale session events, tab switching, cancellation, and provider
availability.

**Verify**: `swift test --filter AgentService` and
`swift test --filter Codex` locally when available; otherwise the GitHub
`Build & Test` job must pass.

### Step 5: Add capability-driven controls and approval UI

Replace the current model/BYOK footer contents in `AgentPanelView` with the
compact provider controls described above. Reuse `AgentInputBox.leadingTools`
and existing theme/menu patterns.

Add the approval view and wire deny/allow actions. Ensure:

- provider cannot change on a nonempty chat;
- no unsupported effort/tier remains selected;
- controls disable during streaming;
- missing executable and signed-out states provide an actionable message;
- Escape/cancel safely denies an outstanding approval;
- VoiceOver/help labels describe controls and approval actions;
- no decorative repeated animation was added.

Prefer extracting small subviews over making `AgentPanelView` own provider
logic.

**Verify**: `swift build` locally when available or the GitHub `Build & Test`
job. Then use the Preview DMG to
and manually inspect empty, loading, ready, streaming, approval, error, and
cancelled states without starting a paid model turn. Record any state that
cannot be reached without a paid turn.

### Step 6: Add Codex settings and lifecycle cleanup

Add asynchronous Codex status/path UI to `AgentPane`, persist only the
executable override, and wire application termination to bounded app-server
shutdown.

Test locator preference persistence separately from account credentials.
Ensure no keychain prompt is introduced by Palmier and no auth file is read by
Palmier code.

**Verify**: `swift test --filter CodexExecutable` and `swift build` locally
when available; otherwise the GitHub `Build & Test` job must pass.

### Step 7: Document and run broad verification

Add a concise README section:

- embedded Codex requires an installed and logged-in Codex CLI;
- Palmier does not store the Codex credential;
- provider/model/reasoning/speed are selected in chat;
- Codex uses Palmier's in-process tools and skills;
- Claude Code is not yet included.

Run the focused and full gates locally when full Xcode is available. Otherwise
dispatch `ci.yml` for `ongrow/codex-provider`, wait for a green `Build & Test`,
and inspect the complete diff for accidental raw payload logging and
out-of-scope changes.

**Verify**:

```bash
swift test --filter Codex
swift test --filter Agent
swift build
swift test
git diff --check
git status --short
```

Expected: local commands that can run exit 0, GitHub CI exits successfully, and
only in-scope files are changed.

## Test plan

Create deterministic Swift Testing suites under
`Tests/PalmierProTests/Agent/`:

- `CodexSessionTests.swift`
- `CodexExecutableLocatorTests.swift`
- `CodexAppServerProtocolTests.swift`
- `CodexAppServerTransportTests.swift`
- `CodexProviderTests.swift`
- `CodexAgentServiceTests.swift`

Use temporary directories and fake executable files for locator tests. Use an
in-memory/fake line transport for JSON-RPC. Do not depend on the developer's
actual `~/.codex`, executable path, model catalog, login, Palmier project, or
network.

Required cases:

- legacy persistence;
- catalog pagination and capability normalization;
- text streaming;
- dynamic tool success/error/image result;
- approval allow/deny/cancel;
- interrupt and process crash;
- stale thread/turn/session events ignored;
- multiple concurrent chat threads do not cross-route;
- missing executable, signed-out account, incompatible protocol;
- unknown fields and notifications remain forward-compatible;
- no secret environment forwarding.

Use the existing Swift Testing style (`@Suite`, `@Test`, `#expect`,
`#require`). A test that only checks a success receipt is insufficient; assert
the emitted chat blocks and captured fake tool execution independently.

## Manual acceptance test

The executor must prepare these steps but must not incur model cost without
operator approval:

1. Launch a debug Palmier build with the real Codex CLI installed and logged in.
2. Open a disposable `.palmier` project.
3. Open Chat and create a new Codex session.
4. Confirm model choices equal the current app-server catalog.
5. Select a model, nondefault reasoning level, and Normal/Fast where available.
6. Send a harmless prompt asking Codex to inspect the empty timeline.
7. Confirm text streams and the Palmier tool row completes.
8. Ask for a reversible timeline edit; confirm it is performed through the
   existing Palmier tool and undo works.
9. Trigger a safe built-in action that requests approval; deny it and confirm
   the turn continues or reports denial correctly.
10. Start a turn, press Stop, and confirm no further text/tool execution is
    applied.
11. Save, quit, reopen the project, select the chat, and confirm the Codex
    thread resumes.
12. Open two projects and verify tool calls remain bound to the originating
    project.

## Done criteria

All must hold:

- [ ] `swift build` exits 0.
- [ ] `swift test` exits 0.
- [ ] Focused Codex tests cover JSON-RPC, transport, catalog, provider,
      dynamic tools, approvals, cancellation, persistence, and routing.
- [ ] Palmier Cloud and Anthropic BYOK behavior still pass existing tests and
      compile without UI regressions.
- [ ] A Codex chat persists an opaque thread ID and provider selections in its
      project package while legacy chat JSON still decodes.
- [ ] Models, reasoning efforts, and speed tiers come only from `model/list`.
- [ ] Codex receives `ToolDefinitions.inAppAgent` and current Palmier skills.
- [ ] Codex tool calls execute only through the session's existing
      `ToolExecutor`.
- [ ] No approval-bypass or danger-full-access launch option exists in the
      changed code.
- [ ] Cancelling/closing/shutting down resolves approvals and terminates work
      without cross-session mutations.
- [ ] No raw prompt/tool/auth/environment payload is logged or sent to
      analytics.
- [ ] Provider controls match existing Palmier theme/density and expose
      keyboard/help labels.
- [ ] Settings reports Codex status and supports a safe executable override.
- [ ] README documents requirements and credential ownership.
- [ ] `git diff --check` passes.
- [ ] `git status --short` lists no file outside the in-scope paths.
- [ ] Executor commits the isolated worktree with repository-style message.

## STOP conditions

Stop and report instead of improvising if:

- In-scope code has semantically drifted from the excerpts since `118fe1c`.
- The installed/generated app-server protocol lacks `dynamicTools`,
  `item/tool/call`, `model/list`, `turn/interrupt`, or correlated approval
  responses.
- Using Codex authentication would require Palmier to read, copy, or rewrite a
  credential or `~/.codex/auth.json`.
- The implementation appears to require danger-full-access or bypassing
  approvals for Palmier dynamic tools.
- Correct routing cannot guarantee that a dynamic tool call reaches only the
  project/session that owns its thread and turn.
- Existing Palmier/Anthropic chat behavior cannot be preserved behind the
  provider abstraction without changing its user-visible contract.
- A required GitHub CI verification fails twice for the same unresolved
  architectural reason after one reasonable correction.
- Completing the feature requires touching an out-of-scope subsystem.
- A live paid model request is the only remaining way to verify automated done
  criteria; leave it for the operator acceptance test instead.

## Maintenance notes

- Codex app-server is experimental. Keep wire decoding isolated under
  `Agent/Codex`; provider-neutral and UI code must not depend on raw method
  strings or JSON dictionaries.
- Future Claude Code work must implement the same provider runtime/event
  abstraction and reuse the same session selection, approval UI, tool bridge,
  and persistence fields where applicable.
- Review every future Codex CLI upgrade against initialization, catalog,
  approval response enums, dynamic-tool payloads, and turn completion errors.
- If provider-specific activity grows beyond Palmier dynamic tools, extend the
  neutral activity model deliberately rather than persisting arbitrary Codex
  JSON in project packages.
- Keep provider session IDs opaque. Never infer filesystem paths from them.
