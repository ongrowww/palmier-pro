import Foundation

enum AgentProviderID: String, Codable, CaseIterable, Sendable {
    case palmier
    case codex

    var displayName: String {
        switch self {
        case .palmier: "Palmier"
        case .codex: "Codex"
        }
    }
}

enum AgentProviderAvailability: Equatable, Sendable {
    case loading
    case available
    case missingExecutable
    case signedOut
    case incompatible(String)
    case failed(String)

    var canSend: Bool {
        if case .available = self { return true }
        return false
    }
}

struct AgentProviderModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let defaultReasoningEffort: String?
    let supportedReasoningEfforts: [String]
    let defaultServiceTier: String?
    let supportedServiceTiers: [AgentServiceTier]
}

struct AgentServiceTier: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let detail: String?
}

struct AgentProviderCatalog: Equatable, Sendable {
    let models: [AgentProviderModel]

    func normalized(
        modelID: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) -> AgentProviderSelection {
        let model = models.first(where: { $0.id == modelID }) ?? models.first
        let effort = model.flatMap { model in
            if let reasoningEffort, model.supportedReasoningEfforts.contains(reasoningEffort) {
                return reasoningEffort
            }
            if let defaultEffort = model.defaultReasoningEffort,
               model.supportedReasoningEfforts.contains(defaultEffort) {
                return defaultEffort
            }
            return model.supportedReasoningEfforts.first
        }
        let tier = model.flatMap { model in
            if let serviceTier, model.supportedServiceTiers.contains(where: { $0.id == serviceTier }) {
                return serviceTier
            }
            if let defaultTier = model.defaultServiceTier,
               model.supportedServiceTiers.contains(where: { $0.id == defaultTier }) {
                return defaultTier
            }
            return nil
        }
        return AgentProviderSelection(modelID: model?.id, reasoningEffort: effort, serviceTier: tier)
    }
}

struct AgentProviderSelection: Codable, Equatable, Sendable {
    var modelID: String?
    var reasoningEffort: String?
    var serviceTier: String?
}

enum AgentApprovalKind: String, Sendable {
    case command
    case fileChange
    case permission
    case elicitation
}

enum AgentApprovalDecision: String, Sendable {
    case deny
    case allowOnce
    case allowForSession
}

struct AgentApprovalRequest: Identifiable, Equatable, Sendable {
    let id: String
    let threadID: String
    let turnID: String
    let kind: AgentApprovalKind
    let summary: String
    let reason: String?
    let allowsSessionDecision: Bool
}

enum AgentProviderEvent: Sendable {
    case textDelta(String)
    case toolStarted(id: String, name: String, inputJSON: String)
    case toolCompleted(id: String, content: [ToolResult.Block], isError: Bool)
    case approvalRequested(AgentApprovalRequest)
    case approvalResolved(String)
    case completed
}

struct AgentProviderTurn: Sendable {
    let threadID: String
    let events: AsyncThrowingStream<AgentProviderEvent, Error>
}

@MainActor
protocol AgentProviderRuntime: AnyObject {
    var catalog: AgentProviderCatalog { get }
    var availability: AgentProviderAvailability { get }

    func prepare() async
    func startTurn(
        threadID: String?,
        selection: AgentProviderSelection,
        text: String,
        imagePaths: [URL],
        cwd: URL,
        instructions: String
    ) async throws -> AgentProviderTurn
    func resolveApproval(id: String, decision: AgentApprovalDecision) async
    func cancel(threadID: String) async
}

enum AgentProviderError: LocalizedError, Sendable {
    case unavailable(String)
    case incompatible(String)
    case signedOut
    case missingThread
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): detail
        case .incompatible(let detail): "Incompatible Codex CLI: \(detail)"
        case .signedOut: "Sign in to Codex before starting a chat."
        case .missingThread: "This Codex thread is no longer available. Start a new Codex chat."
        case .protocolFailure(let detail): "Codex app-server error: \(detail)"
        }
    }
}
