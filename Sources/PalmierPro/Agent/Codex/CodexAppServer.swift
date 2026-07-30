import Foundation

enum CodexAppServerError: LocalizedError, Sendable {
    case executableMissing
    case notRunning
    case invalidJSON
    case malformedResponse
    case rpc(code: Int, message: String)
    case terminated

    var errorDescription: String? {
        switch self {
        case .executableMissing: "Codex CLI is not installed."
        case .notRunning: "Codex app-server is not running."
        case .invalidJSON: "Codex app-server returned invalid JSON."
        case .malformedResponse: "Codex app-server returned an incompatible response."
        case .rpc(let code, let message): "Codex app-server error \(code): \(message)"
        case .terminated: "Codex app-server stopped unexpectedly."
        }
    }
}

enum CodexAppServerInbound: Sendable {
    case notification(method: String, params: CodexJSON)
    case request(id: CodexRPCID, method: String, params: CodexJSON)
    case failure(CodexAppServerError)
}

protocol CodexAppServerServing: Sendable {
    func start() async throws
    func request(method: String, params: CodexJSON) async throws -> CodexJSON
    func notify(method: String, params: CodexJSON) async throws
    func respond(id: CodexRPCID, result: CodexJSON) async throws
    func respond(id: CodexRPCID, error: CodexRPCErrorPayload) async throws
    func events() async -> AsyncStream<CodexAppServerInbound>
    func shutdown() async
}

actor CodexAppServer: CodexAppServerServing {
    static let shared = CodexAppServer()

    private var process: Process?
    private var inputHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var isStarting = false
    private var isInitialized = false
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<CodexJSON, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<CodexAppServerInbound>.Continuation] = [:]
    private var stderrTail = Data()
    private let stderrLimit = 8_192
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func start() async throws {
        if process?.isRunning == true, isInitialized { return }
        if isStarting {
            while isStarting {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            if process?.isRunning == true, isInitialized { return }
            try await start()
            return
        }
        isStarting = true
        defer { isStarting = false }
        let status = await Task.detached(priority: .utility) { CodexExecutableLocator.locate() }.value
        guard let executableURL = status.url else { throw CodexAppServerError.executableMissing }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = CodexExecutableLocator.allowedEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in
            Task { await self?.didTerminate() }
        }
        do {
            try process.run()
            self.process = process
            inputHandle = input.fileHandleForWriting
            stderrTail.removeAll(keepingCapacity: true)

            stdoutTask = Task { [weak self] in
                var buffer = CodexLineBuffer()
                do {
                    for try await byte in output.fileHandleForReading.bytes {
                        let lines = buffer.append(Data([byte]))
                        for line in lines { await self?.receive(line) }
                    }
                } catch {
                    await self?.didTerminate()
                }
            }
            stderrTask = Task { [weak self] in
                do {
                    for try await byte in errors.fileHandleForReading.bytes {
                        await self?.appendStderr(Data([byte]))
                    }
                } catch {}
            }

            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object(["name": .string("Palmier Pro"), "version": .string("1")]),
                    "capabilities": .object(["experimentalApi": .bool(true)]),
                ])
            )
            try await notify(method: "initialized", params: .object([:]))
            isInitialized = true
        } catch {
            stopProcess(failingPendingWith: error, finishEvents: true)
            throw error
        }
    }

    func request(method: String, params: CodexJSON) async throws -> CodexJSON {
        guard inputHandle != nil else { throw CodexAppServerError.notRunning }
        let id = nextRequestID
        nextRequestID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(CodexRPCEnvelope(id: .number(id), method: method, params: params))
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    func notify(method: String, params: CodexJSON) async throws {
        try write(CodexRPCEnvelope(method: method, params: params))
    }

    func respond(id: CodexRPCID, result: CodexJSON) async throws {
        try write(CodexRPCEnvelope(id: id, result: result))
    }

    func respond(id: CodexRPCID, error: CodexRPCErrorPayload) async throws {
        try write(CodexRPCEnvelope(id: id, error: error))
    }

    func events() -> AsyncStream<CodexAppServerInbound> {
        let token = UUID()
        return AsyncStream { continuation in
            eventContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(token) }
            }
        }
    }

    func shutdown() async {
        stopProcess(failingPendingWith: CancellationError(), finishEvents: true)
    }

    private func write(_ envelope: CodexRPCEnvelope) throws {
        guard let inputHandle else { throw CodexAppServerError.notRunning }
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ line: Data) {
        guard let envelope = try? decoder.decode(CodexRPCEnvelope.self, from: line) else {
            let error = CodexAppServerError.invalidJSON
            failPending(error)
            emit(.failure(error))
            return
        }
        if let id = envelope.id, envelope.method == nil {
            guard case .number(let numericID) = id,
                  let continuation = pending.removeValue(forKey: numericID) else { return }
            if let error = envelope.error {
                continuation.resume(throwing: CodexAppServerError.rpc(code: error.code, message: error.message))
            } else if let result = envelope.result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CodexAppServerError.malformedResponse)
            }
        } else if let method = envelope.method, let id = envelope.id {
            emit(.request(id: id, method: method, params: envelope.params ?? .object([:])))
        } else if let method = envelope.method {
            emit(.notification(method: method, params: envelope.params ?? .object([:])))
        }
    }

    private func emit(_ event: CodexAppServerInbound) {
        eventContinuations.values.forEach { $0.yield(event) }
    }

    private func appendStderr(_ data: Data) {
        stderrTail.append(data)
        if stderrTail.count > stderrLimit {
            stderrTail.removeFirst(stderrTail.count - stderrLimit)
        }
    }

    private func didTerminate() {
        guard process != nil else { return }
        let error = CodexAppServerError.terminated
        emit(.failure(error))
        stopProcess(failingPendingWith: error, finishEvents: true)
    }

    private func stopProcess(failingPendingWith error: Error, finishEvents: Bool) {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
        failPending(error)
        if finishEvents {
            eventContinuations.values.forEach { $0.finish() }
            eventContinuations.removeAll()
        }
        try? inputHandle?.close()
        inputHandle = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        isInitialized = false
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func cancelRequest(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
