import Foundation
import Observation

enum FALKeychain {
    private static let account = "api-key"
    private static let service = "de.ongrow.palmier-pro.fal"

    static func save(_ key: String) throws {
        try KeychainStore.save(key, account: account, service: service)
    }

    static func load() throws -> String? {
        try KeychainStore.load(account: account, service: service)
    }

    static func delete() throws {
        try KeychainStore.delete(account: account, service: service)
    }
}

@MainActor
@Observable
final class FALCredentialState {
    enum Status {
        case unknown
        case missing
        case stored
        case failed(String)
    }

    static let shared = FALCredentialState()

    private(set) var status: Status = .unknown
    private var refreshTask: Task<Void, Never>?
    private var revision = 0

    var hasKey: Bool {
        if case .stored = status { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    private init() {}

    func refresh() {
        revision += 1
        let currentRevision = revision
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return CredentialLoadResult.success(hasKey: try FALKeychain.load() != nil)
                } catch {
                    return CredentialLoadResult.failure(error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled, let self, revision == currentRevision else { return }
            switch result {
            case .success(let hasKey):
                status = hasKey ? .stored : .missing
            case .failure(let message):
                status = .failed(message)
            }
        }
    }

    func save(_ key: String) async -> Bool {
        revision += 1
        let currentRevision = revision
        refreshTask?.cancel()
        let result = await Task.detached(priority: .userInitiated) {
            do {
                try FALKeychain.save(key)
                return CredentialOperationResult.success
            } catch {
                return CredentialOperationResult.failure(error.localizedDescription)
            }
        }.value
        guard revision == currentRevision else { return false }
        switch result {
        case .success:
            status = .stored
            return true
        case .failure(let message):
            status = .failed(message)
            return false
        }
    }

    func delete() async -> Bool {
        revision += 1
        let currentRevision = revision
        refreshTask?.cancel()
        let result = await Task.detached(priority: .userInitiated) {
            do {
                try FALKeychain.delete()
                return CredentialOperationResult.success
            } catch {
                return CredentialOperationResult.failure(error.localizedDescription)
            }
        }.value
        guard revision == currentRevision else { return false }
        switch result {
        case .success:
            status = .missing
            return true
        case .failure(let message):
            status = .failed(message)
            return false
        }
    }
}

private enum CredentialLoadResult: Sendable {
    case success(hasKey: Bool)
    case failure(String)
}

private enum CredentialOperationResult: Sendable {
    case success
    case failure(String)
}

protocol FALCredentialProviding: Sendable {
    func apiKey() async throws -> String
}

struct FALKeychainCredentialProvider: FALCredentialProviding {
    func apiKey() async throws -> String {
        let key = try await Task.detached(priority: .userInitiated) {
            try FALKeychain.load()
        }.value
        guard let key else {
            throw FALClientError.missingAPIKey
        }
        return key
    }
}
