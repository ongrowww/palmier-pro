import Foundation
import Testing
@testable import PalmierPro

private actor FakeCodexAppServer: CodexAppServerServing {
    struct Call: Sendable {
        let method: String
        let params: CodexJSON
    }

    struct Response: Sendable {
        let id: CodexRPCID
        let result: CodexJSON?
        let error: CodexRPCErrorPayload?
    }

    private var continuation: AsyncStream<CodexAppServerInbound>.Continuation?
    private(set) var calls: [Call] = []
    private(set) var responses: [Response] = []
    var account: CodexJSON = .object([
        "account": .object(["type": .string("chatgpt"), "email": .null, "planType": .string("pro")]),
        "requiresOpenaiAuth": .bool(true),
    ])

    func start() async throws {}

    func request(method: String, params: CodexJSON) async throws -> CodexJSON {
        calls.append(Call(method: method, params: params))
        switch method {
        case "account/read":
            return account
        case "model/list":
            return .object([
                "data": .array([
                    .object([
                        "id": .string("model-test"),
                        "displayName": .string("Model Test"),
                        "defaultReasoningEffort": .string("medium"),
                        "supportedReasoningEfforts": .array([
                            .object(["reasoningEffort": .string("low"), "description": .string("Low")]),
                            .object(["reasoningEffort": .string("medium"), "description": .string("Medium")]),
                        ]),
                        "defaultServiceTier": .null,
                        "serviceTiers": .array([
                            .object([
                                "id": .string("priority"),
                                "name": .string("Fast"),
                                "description": .string("Faster"),
                            ]),
                        ]),
                    ]),
                ]),
                "nextCursor": .null,
            ])
        case "thread/start":
            return .object(["thread": .object(["id": .string("thread-test")])])
        case "thread/resume":
            return .object([
                "thread": .object([
                    "id": params["threadId"] ?? .string("thread-test"),
                ]),
            ])
        case "turn/start":
            return .object(["turn": .object(["id": .string("turn-test")])])
        case "turn/interrupt":
            return .object([:])
        default:
            throw CodexAppServerError.rpc(code: -32601, message: "Unexpected test method \(method)")
        }
    }

    func notify(method: String, params: CodexJSON) async throws {
        calls.append(Call(method: method, params: params))
    }

    func respond(id: CodexRPCID, result: CodexJSON) async throws {
        responses.append(Response(id: id, result: result, error: nil))
    }

    func respond(id: CodexRPCID, error: CodexRPCErrorPayload) async throws {
        responses.append(Response(id: id, result: nil, error: error))
    }

    func events() async -> AsyncStream<CodexAppServerInbound> {
        let pair = AsyncStream<CodexAppServerInbound>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func shutdown() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: CodexAppServerInbound) async {
        while continuation == nil {
            await Task.yield()
        }
        continuation?.yield(event)
    }

    func call(_ method: String) -> Call? {
        calls.last { $0.method == method }
    }
}

@Suite("CodexProvider")
@MainActor
struct CodexProviderTests {
    @Test func preparesDynamicCatalogAndStartsSafeThread() async throws {
        let fake = FakeCodexAppServer()
        let harness = ToolHarness()
        let provider = CodexProvider(server: fake, toolExecutor: harness.executor)
        await provider.prepare()

        #expect(provider.availability == .available)
        #expect(provider.catalog.models.map(\.id) == ["model-test"])
        #expect(provider.catalog.models[0].supportedReasoningEfforts == ["low", "medium"])
        #expect(provider.catalog.models[0].supportedServiceTiers.map(\.id) == ["priority"])

        let turn = try await provider.startTurn(
            threadID: nil,
            selection: AgentProviderSelection(
                modelID: "model-test",
                reasoningEffort: "medium",
                serviceTier: "priority"
            ),
            text: "Inspect the timeline",
            imagePaths: [],
            cwd: URL(fileURLWithPath: "/tmp/test-project.palmier"),
            instructions: "Use Palmier tools."
        )

        #expect(turn.threadID == "thread-test")
        let threadCall = try #require(await fake.call("thread/start"))
        #expect(threadCall.params["sandbox"] == .string("read-only"))
        #expect(threadCall.params["approvalPolicy"] == .string("on-request"))
        let tools = try #require(threadCall.params["dynamicTools"]?.arrayValue)
        #expect(tools.contains { $0["name"] == .string("get_timeline") })
        #expect(tools.contains { $0["name"] == .string("read_skill") })

        let turnCall = try #require(await fake.call("turn/start"))
        #expect(turnCall.params["model"] == .string("model-test"))
        #expect(turnCall.params["effort"] == .string("medium"))
        #expect(turnCall.params["serviceTier"] == .string("priority"))

        await provider.cancel(threadID: turn.threadID)
    }

    @Test func streamsTextAndRoutesPalmierToolResult() async throws {
        let fake = FakeCodexAppServer()
        let harness = ToolHarness()
        let provider = CodexProvider(server: fake, toolExecutor: harness.executor)
        await provider.prepare()
        let turn = try await provider.startTurn(
            threadID: nil,
            selection: AgentProviderSelection(
                modelID: "model-test",
                reasoningEffort: "medium",
                serviceTier: nil
            ),
            text: "Inspect",
            imagePaths: [],
            cwd: URL(fileURLWithPath: "/tmp/test-project.palmier"),
            instructions: "Use Palmier tools."
        )

        let collection = Task { @MainActor in
            var text = ""
            var startedTool: String?
            var completedTool = false
            for try await event in turn.events {
                switch event {
                case .textDelta(let delta): text += delta
                case .toolStarted(_, let name, _): startedTool = name
                case .toolCompleted: completedTool = true
                default: break
                }
            }
            return (text, startedTool, completedTool)
        }

        await fake.emit(.notification(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string("thread-test"),
                "turnId": .string("turn-test"),
                "delta": .string("Timeline inspected."),
            ])
        ))
        await fake.emit(.request(
            id: .number(90),
            method: "item/tool/call",
            params: .object([
                "threadId": .string("thread-test"),
                "turnId": .string("turn-test"),
                "callId": .string("call-1"),
                "tool": .string("get_timeline"),
                "arguments": .object([:]),
            ])
        ))
        try await waitUntil { await fake.responses.count == 1 }
        let response = try #require(await fake.responses.first?.result)
        #expect(response["success"] == .bool(true))
        #expect(response["contentItems"]?.arrayValue?.isEmpty == false)

        await fake.emit(.notification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("thread-test"),
                "turn": .object([
                    "id": .string("turn-test"),
                    "status": .string("completed"),
                ]),
            ])
        ))
        let result = try await collection.value
        #expect(result.0 == "Timeline inspected.")
        #expect(result.1 == "get_timeline")
        #expect(result.2)
    }

    @Test func resumesPersistedThreadWithCurrentSafetySettings() async throws {
        let fake = FakeCodexAppServer()
        let harness = ToolHarness()
        let provider = CodexProvider(server: fake, toolExecutor: harness.executor)
        await provider.prepare()

        let turn = try await provider.startTurn(
            threadID: "persisted-thread",
            selection: AgentProviderSelection(
                modelID: "model-test",
                reasoningEffort: "medium",
                serviceTier: nil
            ),
            text: "Continue",
            imagePaths: [],
            cwd: URL(fileURLWithPath: "/tmp/test-project.palmier"),
            instructions: "Use Palmier tools."
        )

        #expect(turn.threadID == "persisted-thread")
        let resumeCall = try #require(await fake.call("thread/resume"))
        #expect(resumeCall.params["threadId"] == .string("persisted-thread"))
        #expect(resumeCall.params["sandbox"] == .string("read-only"))
        #expect(resumeCall.params["approvalPolicy"] == .string("on-request"))
        await provider.cancel(threadID: turn.threadID)
    }

    @Test func ignoresToolRequestOwnedByAnotherProjectProvider() async throws {
        let fake = FakeCodexAppServer()
        let harness = ToolHarness()
        let provider = CodexProvider(server: fake, toolExecutor: harness.executor)
        await provider.prepare()
        let turn = try await provider.startTurn(
            threadID: nil,
            selection: AgentProviderSelection(
                modelID: "model-test",
                reasoningEffort: "medium",
                serviceTier: nil
            ),
            text: "Inspect",
            imagePaths: [],
            cwd: URL(fileURLWithPath: "/tmp/test-project.palmier"),
            instructions: "Use Palmier tools."
        )

        await fake.emit(.request(
            id: .number(91),
            method: "item/tool/call",
            params: .object([
                "threadId": .string("another-thread"),
                "turnId": .string("another-turn"),
                "callId": .string("foreign-call"),
                "tool": .string("get_timeline"),
                "arguments": .object([:]),
            ])
        ))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fake.responses.isEmpty)
        await provider.cancel(threadID: turn.threadID)
    }

    @Test func resolvesCommandApprovalAndInterruptsTurn() async throws {
        let fake = FakeCodexAppServer()
        let harness = ToolHarness()
        let provider = CodexProvider(server: fake, toolExecutor: harness.executor)
        await provider.prepare()
        let turn = try await provider.startTurn(
            threadID: nil,
            selection: AgentProviderSelection(
                modelID: "model-test",
                reasoningEffort: "medium",
                serviceTier: nil
            ),
            text: "Inspect",
            imagePaths: [],
            cwd: URL(fileURLWithPath: "/tmp/test-project.palmier"),
            instructions: "Use Palmier tools."
        )
        let approvalTask = Task { @MainActor in
            for try await event in turn.events {
                if case .approvalRequested(let request) = event { return request }
            }
            throw AgentProviderError.protocolFailure("Approval stream ended.")
        }

        await fake.emit(.request(
            id: .string("approval-1"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-test"),
                "turnId": .string("turn-test"),
                "command": .string("touch test"),
                "reason": .string("Test approval"),
            ])
        ))
        let approval = try await approvalTask.value
        #expect(approval.kind == .command)
        #expect(approval.allowsSessionDecision)

        await provider.resolveApproval(id: approval.id, decision: .allowOnce)
        let response = try #require(await fake.responses.last?.result)
        #expect(response["decision"] == .string("accept"))

        await provider.cancel(threadID: turn.threadID)
        #expect(await fake.call("turn/interrupt") != nil)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                throw AgentProviderError.protocolFailure("Timed out waiting for fake app-server state.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
