import Foundation

@MainActor
final class CodexProvider: AgentProviderRuntime {
    private struct ActiveTurn {
        let threadID: String
        let turnID: String
        let continuation: AsyncThrowingStream<AgentProviderEvent, Error>.Continuation
    }

    private struct PendingApproval {
        let rpcID: CodexRPCID
        let request: AgentApprovalRequest
        let method: String
        let requestedPermissions: CodexJSON?
    }

    private let server: any CodexAppServerServing
    private let toolExecutor: ToolExecutor
    private var listenerTask: Task<Void, Never>?
    private var activeTurns: [String: ActiveTurn] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private(set) var catalog = AgentProviderCatalog(models: [])
    private(set) var availability: AgentProviderAvailability = .loading

    init(server: any CodexAppServerServing = CodexAppServer.shared, toolExecutor: ToolExecutor) {
        self.server = server
        self.toolExecutor = toolExecutor
        listenerTask = Task { [weak self] in await self?.listen() }
    }

    deinit { listenerTask?.cancel() }

    func prepare() async {
        availability = .loading
        do {
            try await server.start()
            let account = try await server.request(
                method: "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
            guard let accountValue = account["account"], accountValue != .null else {
                availability = .signedOut
                return
            }
            catalog = try await loadCatalog()
            guard !catalog.models.isEmpty else {
                availability = .incompatible("model/list returned no selectable models.")
                return
            }
            availability = .available
        } catch CodexAppServerError.executableMissing {
            availability = .missingExecutable
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func startTurn(
        threadID existingThreadID: String?,
        selection: AgentProviderSelection,
        text: String,
        imagePaths: [URL],
        cwd: URL,
        instructions: String
    ) async throws -> AgentProviderTurn {
        try await server.start()
        let threadID: String
        if let existingThreadID {
            let response: CodexJSON
            do {
                response = try await server.request(
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(existingThreadID),
                        "cwd": .string(cwd.path),
                        "model": selection.modelID.map(CodexJSON.string) ?? .null,
                        "approvalPolicy": .string("on-request"),
                        "sandbox": .string("read-only"),
                        "developerInstructions": .string(instructions),
                        "serviceTier": selection.serviceTier.map(CodexJSON.string) ?? .null,
                    ])
                )
            } catch {
                throw Self.mapThreadError(error)
            }
            guard let resumedThreadID = response["thread"]?["id"]?.stringValue else {
                throw AgentProviderError.incompatible("thread/resume did not return a thread ID.")
            }
            threadID = resumedThreadID
        } else {
            let response = try await server.request(
                method: "thread/start",
                params: .object([
                    "cwd": .string(cwd.path),
                    "model": selection.modelID.map(CodexJSON.string) ?? .null,
                    "approvalPolicy": .string("on-request"),
                    "sandbox": .string("read-only"),
                    "developerInstructions": .string(instructions),
                    "dynamicTools": .array(try dynamicToolSpecs()),
                    "serviceTier": selection.serviceTier.map(CodexJSON.string) ?? .null,
                    "ephemeral": .bool(false),
                ])
            )
            guard let value = response["thread"]?["id"]?.stringValue else {
                throw AgentProviderError.incompatible("thread/start did not return a thread ID.")
            }
            threadID = value
        }
        guard activeTurns[threadID] == nil else {
            throw AgentProviderError.protocolFailure("This Codex thread already has an active turn.")
        }

        var inputs: [CodexJSON] = [
            .object(["type": .string("text"), "text": .string(text)]),
        ]
        inputs.append(contentsOf: imagePaths.map {
            .object(["type": .string("localImage"), "path": .string($0.path)])
        })

        let response: CodexJSON
        do {
            response = try await server.request(
                method: "turn/start",
                params: .object([
                    "threadId": .string(threadID),
                    "input": .array(inputs),
                    "model": selection.modelID.map(CodexJSON.string) ?? .null,
                    "effort": selection.reasoningEffort.map(CodexJSON.string) ?? .null,
                    "serviceTier": selection.serviceTier.map(CodexJSON.string) ?? .null,
                    "approvalPolicy": .string("on-request"),
                ])
            )
        } catch {
            throw Self.mapThreadError(error)
        }
        guard let turnID = response["turn"]?["id"]?.stringValue else {
            throw AgentProviderError.incompatible("turn/start did not return a turn ID.")
        }

        var streamContinuation: AsyncThrowingStream<AgentProviderEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<AgentProviderEvent, Error> { continuation in
            streamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in await self?.cancel(threadID: threadID) }
            }
        }
        guard let streamContinuation else {
            throw AgentProviderError.protocolFailure("Could not create the Codex event stream.")
        }
        activeTurns[threadID] = ActiveTurn(
            threadID: threadID,
            turnID: turnID,
            continuation: streamContinuation
        )
        return AgentProviderTurn(threadID: threadID, events: stream)
    }

    func resolveApproval(id: String, decision: AgentApprovalDecision) async {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        do {
            let result: CodexJSON
            switch pending.method {
            case "item/permissions/requestApproval":
                if decision == .deny {
                    result = .object([
                        "permissions": .object([
                            "fileSystem": .object(["entries": .array([])]),
                            "network": .object(["enabled": .bool(false)]),
                        ]),
                        "scope": .string("turn"),
                    ])
                } else {
                    result = .object([
                        "permissions": pending.requestedPermissions ?? .object([:]),
                        "scope": .string(decision == .allowForSession ? "session" : "turn"),
                    ])
                }
            case "mcpServer/elicitation/request":
                result = .object(["action": .string(decision == .deny ? "decline" : "accept")])
            default:
                let value: String = switch decision {
                case .deny: "decline"
                case .allowOnce: "accept"
                case .allowForSession: "acceptForSession"
                }
                result = .object(["decision": .string(value)])
            }
            try await server.respond(id: pending.rpcID, result: result)
            activeTurns[pending.request.threadID]?.continuation.yield(.approvalResolved(id))
        } catch {
            activeTurns[pending.request.threadID]?.continuation.finish(throwing: error)
            activeTurns.removeValue(forKey: pending.request.threadID)
        }
    }

    func cancel(threadID: String) async {
        guard let active = activeTurns.removeValue(forKey: threadID) else { return }
        let approvals = pendingApprovals.values.filter { $0.request.threadID == threadID }
        for approval in approvals {
            await resolveApproval(id: approval.request.id, decision: .deny)
        }
        _ = try? await server.request(
            method: "turn/interrupt",
            params: .object(["threadId": .string(threadID), "turnId": .string(active.turnID)])
        )
        active.continuation.finish(throwing: CancellationError())
    }

    private func listen() async {
        while !Task.isCancelled {
            let events = await server.events()
            for await inbound in events {
                if Task.isCancelled { return }
                switch inbound {
                case .notification(let method, let params):
                    handleNotification(method: method, params: params)
                case .request(let id, let method, let params):
                    await handleServerRequest(id: id, method: method, params: params)
                case .failure(let error):
                    failActiveTurns(with: error)
                }
            }
            if !Task.isCancelled {
                await Task.yield()
            }
        }
    }

    private func handleNotification(method: String, params: CodexJSON) {
        guard let threadID = params["threadId"]?.stringValue,
              let active = activeTurns[threadID] else { return }
        if let turnID = params["turnId"]?.stringValue, turnID != active.turnID { return }

        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue, !delta.isEmpty {
                active.continuation.yield(.textDelta(delta))
            }
        case "turn/completed":
            let status = params["turn"]?["status"]?.stringValue
            if status == "completed" {
                active.continuation.yield(.completed)
                active.continuation.finish()
            } else if status == "interrupted" {
                active.continuation.finish(throwing: CancellationError())
            } else {
                let message = params["turn"]?["error"]?["message"]?.stringValue ?? "The Codex turn failed."
                active.continuation.finish(throwing: AgentProviderError.protocolFailure(message))
            }
            pendingApprovals = pendingApprovals.filter { $0.value.request.threadID != threadID }
            activeTurns.removeValue(forKey: threadID)
        default:
            break
        }
    }

    private func handleServerRequest(id: CodexRPCID, method: String, params: CodexJSON) async {
        guard let threadID = params["threadId"]?.stringValue,
              activeTurns[threadID] != nil else {
            return
        }
        switch method {
        case "item/tool/call":
            await handleToolCall(id: id, params: params)
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval":
            handleApproval(id: id, method: method, params: params)
        case "mcpServer/elicitation/request":
            try? await server.respond(
                id: id,
                result: .object(["action": .string("decline")])
            )
        default:
            try? await server.respond(
                id: id,
                error: CodexRPCErrorPayload(code: -32601, message: "Unsupported app-server request.")
            )
        }
    }

    private func handleToolCall(id: CodexRPCID, params: CodexJSON) async {
        guard let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let active = activeTurns[threadID],
              active.turnID == turnID,
              let callID = params["callId"]?.stringValue,
              let name = params["tool"]?.stringValue,
              ToolDefinitions.inAppAgent.contains(where: { $0.name.rawValue == name }),
              let arguments = params["arguments"]?.objectValue else {
            try? await server.respond(
                id: id,
                result: .object([
                    "success": .bool(false),
                    "contentItems": .array([.object([
                        "type": .string("inputText"),
                        "text": .string("Rejected an invalid or misrouted Palmier tool call."),
                    ])]),
                ])
            )
            return
        }

        let inputJSON = Self.encodedString(.object(arguments))
        active.continuation.yield(.toolStarted(id: callID, name: name, inputJSON: inputJSON))
        let foundation = arguments.mapValues { $0.foundationObject() }
        let result = await toolExecutor.execute(name: name, args: foundation, source: "codex")
        let contentItems = result.content.map { block -> CodexJSON in
            switch block {
            case .text(let text):
                .object(["type": .string("inputText"), "text": .string(text)])
            case .image(let base64, let mediaType):
                .object([
                    "type": .string("inputImage"),
                    "imageUrl": .string("data:\(mediaType);base64,\(base64)"),
                ])
            }
        }
        do {
            try await server.respond(
                id: id,
                result: .object(["success": .bool(!result.isError), "contentItems": .array(contentItems)])
            )
            active.continuation.yield(
                .toolCompleted(id: callID, content: result.content, isError: result.isError)
            )
        } catch {
            active.continuation.finish(throwing: error)
            activeTurns.removeValue(forKey: threadID)
        }
    }

    private func handleApproval(id: CodexRPCID, method: String, params: CodexJSON) {
        guard let threadID = params["threadId"]?.stringValue,
              let active = activeTurns[threadID],
              let turnID = params["turnId"]?.stringValue,
              turnID == active.turnID else {
            Task {
                try? await server.respond(
                    id: id,
                    error: CodexRPCErrorPayload(code: -32602, message: "Approval was not routed to an active turn.")
                )
            }
            return
        }
        let approvalID = Self.approvalID(id)
        let kind: AgentApprovalKind = switch method {
        case "item/commandExecution/requestApproval": .command
        case "item/fileChange/requestApproval": .fileChange
        default: .permission
        }
        let summary = Self.sanitizedSummary(kind: kind, params: params)
        let allowsSession = params["availableDecisions"]?.arrayValue?.contains(.string("acceptForSession"))
            ?? (kind == .command || kind == .fileChange)
        let request = AgentApprovalRequest(
            id: approvalID,
            threadID: threadID,
            turnID: turnID,
            kind: kind,
            summary: summary,
            reason: params["reason"]?.stringValue,
            allowsSessionDecision: allowsSession
        )
        pendingApprovals[approvalID] = PendingApproval(
            rpcID: id,
            request: request,
            method: method,
            requestedPermissions: params["permissions"]
        )
        active.continuation.yield(.approvalRequested(request))
    }

    private func loadCatalog() async throws -> AgentProviderCatalog {
        var models: [AgentProviderModel] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            let result = try await server.request(
                method: "model/list",
                params: .object([
                    "cursor": cursor.map(CodexJSON.string) ?? .null,
                    "includeHidden": .bool(false),
                ])
            )
            guard let rows = result["data"]?.arrayValue else {
                throw AgentProviderError.incompatible("model/list response has no data array.")
            }
            models.append(contentsOf: rows.compactMap(Self.parseModel))
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw AgentProviderError.incompatible("model/list returned a repeated cursor.")
            }
        } while cursor != nil
        return AgentProviderCatalog(models: models)
    }

    private func dynamicToolSpecs() throws -> [CodexJSON] {
        try ToolDefinitions.inAppAgent.map { tool in
            .object([
                "type": .string("function"),
                "name": .string(tool.name.rawValue),
                "description": .string(tool.description),
                "inputSchema": try CodexJSON.fromFoundation(tool.inputSchema),
            ])
        }
    }

    private static func parseModel(_ json: CodexJSON) -> AgentProviderModel? {
        guard let id = json["id"]?.stringValue,
              let displayName = json["displayName"]?.stringValue else { return nil }
        let efforts = json["supportedReasoningEfforts"]?.arrayValue?.compactMap {
            $0["reasoningEffort"]?.stringValue
        } ?? []
        let tiers = json["serviceTiers"]?.arrayValue?.compactMap { row -> AgentServiceTier? in
            guard let id = row["id"]?.stringValue, let name = row["name"]?.stringValue else { return nil }
            return AgentServiceTier(id: id, displayName: name, detail: row["description"]?.stringValue)
        } ?? []
        return AgentProviderModel(
            id: id,
            displayName: displayName,
            defaultReasoningEffort: json["defaultReasoningEffort"]?.stringValue,
            supportedReasoningEfforts: efforts,
            defaultServiceTier: json["defaultServiceTier"]?.stringValue,
            supportedServiceTiers: tiers
        )
    }

    private static func encodedString(_ value: CodexJSON) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func approvalID(_ id: CodexRPCID) -> String {
        switch id {
        case .number(let value): "rpc-\(value)"
        case .string(let value): "rpc-\(value)"
        }
    }

    private static func mapThreadError(_ error: Error) -> Error {
        guard let codexError = error as? CodexAppServerError,
              case .rpc(_, let message) = codexError,
              message.localizedCaseInsensitiveContains("thread"),
              message.localizedCaseInsensitiveContains("not found") else {
            return error
        }
        return AgentProviderError.missingThread
    }

    private static func sanitizedSummary(kind: AgentApprovalKind, params: CodexJSON) -> String {
        let raw: String = switch kind {
        case .command: params["command"]?.stringValue ?? "Run a command"
        case .fileChange: params["reason"]?.stringValue ?? "Change files"
        case .permission: params["reason"]?.stringValue ?? "Request additional permissions"
        case .elicitation: params["message"]?.stringValue ?? "Answer an external request"
        }
        return String(raw.replacingOccurrences(of: "\n", with: " ").prefix(320))
    }

    private func failActiveTurns(with error: Error) {
        for turn in activeTurns.values {
            turn.continuation.finish(throwing: error)
        }
        activeTurns.removeAll()
        pendingApprovals.removeAll()
    }
}
