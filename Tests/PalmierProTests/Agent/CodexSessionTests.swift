import Foundation
import Testing
@testable import PalmierPro

@Suite("CodexSession")
struct CodexSessionTests {
    @Test func newSessionDefaultsToCodex() {
        #expect(ChatSession().provider == .codex)
    }

    @Test func legacySessionDefaultsToPalmier() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","title":"Legacy","updatedAt":"2026-07-30T10:00:00Z","messages":[],"isOpen":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(ChatSession.self, from: Data(json.utf8))
        #expect(session.provider == .palmier)
        #expect(session.externalThreadID == nil)
    }

    @Test func codexSessionRoundTripsProviderMetadata() throws {
        let original = ChatSession(
            provider: .codex,
            externalThreadID: "thread-opaque",
            selectedModelID: "model-a",
            selectedReasoningEffort: "high",
            selectedServiceTier: "fast"
        )
        let data = try #require(ChatSessionStore.encodeSession(original))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatSession.self, from: data)
        #expect(decoded.provider == .codex)
        #expect(decoded.externalThreadID == "thread-opaque")
        #expect(decoded.selectedModelID == "model-a")
        #expect(decoded.selectedReasoningEffort == "high")
        #expect(decoded.selectedServiceTier == "fast")
    }

    @Test func providerCanChangeOnlyBeforeMessages() {
        var session = ChatSession()
        #expect(session.canChangeProvider)
        session.messages.append(AgentMessage(role: .user, blocks: [.text("Hello")]))
        #expect(!session.canChangeProvider)
    }

    @Test func catalogNormalizesRemovedCapabilities() {
        let catalog = AgentProviderCatalog(models: [
            AgentProviderModel(
                id: "model-b",
                displayName: "Model B",
                defaultReasoningEffort: "medium",
                supportedReasoningEfforts: ["low", "medium"],
                defaultServiceTier: nil,
                supportedServiceTiers: []
            ),
        ])
        let selection = catalog.normalized(
            modelID: "removed",
            reasoningEffort: "high",
            serviceTier: "fast"
        )
        #expect(selection == AgentProviderSelection(
            modelID: "model-b",
            reasoningEffort: "medium",
            serviceTier: nil
        ))
    }
}
