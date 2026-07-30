import Foundation

enum FALJSONValue: Codable, Equatable, Sendable {
    case object([String: FALJSONValue])
    case array([FALJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([FALJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: FALJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: FALJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [FALJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    func imageURLs() throws -> [String] {
        guard let images = objectValue?["images"]?.arrayValue else {
            throw FALImageGenerationError.missingImages
        }
        let urls = images.compactMap { $0.objectValue?["url"]?.stringValue }
        guard !urls.isEmpty else {
            throw FALImageGenerationError.missingImages
        }
        return urls
    }

    func mediaURLs() throws -> [String] {
        guard let object = objectValue else {
            throw FALMediaGenerationError.missingResult
        }
        for key in ["images", "image", "video", "audio"] {
            guard let value = object[key] else { continue }
            let urls = Self.collectURLs(from: value)
            if !urls.isEmpty { return urls }
        }
        let urls = Self.collectURLs(from: self)
        guard !urls.isEmpty else {
            throw FALMediaGenerationError.missingResult
        }
        return urls
    }

    private static func collectURLs(from value: FALJSONValue) -> [String] {
        switch value {
        case .object(let object):
            if let url = object["url"]?.stringValue,
               let parsed = URL(string: url),
               parsed.scheme == "https" {
                return [url]
            }
            return object.keys.sorted().flatMap { key in
                object[key].map(collectURLs(from:)) ?? []
            }
        case .array(let values):
            return values.flatMap(collectURLs(from:))
        case .string, .number, .bool, .null:
            return []
        }
    }
}

struct FALQueueSubmission: Decodable, Equatable, Sendable {
    let requestId: String
    let statusURL: URL
    let responseURL: URL
    let cancelURL: URL

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case statusURL = "status_url"
        case responseURL = "response_url"
        case cancelURL = "cancel_url"
    }
}

struct FALQueueStatus: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable {
        case inQueue = "IN_QUEUE"
        case inProgress = "IN_PROGRESS"
        case completed = "COMPLETED"
    }

    let status: State
    let queuePosition: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case queuePosition = "queue_position"
    }
}

enum FALClientError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidEndpoint
    case untrustedResponseURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add a fal.ai API key in Settings."
        case .invalidEndpoint: "The fal.ai model endpoint is invalid."
        case .untrustedResponseURL: "fal.ai returned an untrusted queue URL."
        case .invalidResponse: "fal.ai returned an invalid response."
        case .httpStatus(let status): "fal.ai request failed (HTTP \(status))."
        }
    }
}

struct FALQueueRequestBuilder {
    private static let queueBaseURL = URL(string: "https://queue.fal.run")!

    static func submitRequest(
        endpoint: String,
        input: [String: FALJSONValue],
        apiKey: String
    ) throws -> URLRequest {
        let endpoint = try validatedEndpoint(endpoint)
        let url = queueBaseURL.appending(path: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            #"{"expiration_duration_seconds":86400}"#,
            forHTTPHeaderField: "X-Fal-Object-Lifecycle-Preference"
        )
        request.httpBody = try JSONEncoder().encode(input)
        return request
    }

    static func authenticatedRequest(url: URL, method: String, apiKey: String) throws -> URLRequest {
        guard url.scheme == "https",
              url.host == "queue.fal.run",
              url.port == nil,
              url.user == nil,
              url.password == nil else {
            throw FALClientError.untrustedResponseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func submission(endpoint: String, requestId: String) throws -> FALQueueSubmission {
        let endpoint = try validatedEndpoint(endpoint)
        let requestId = try validatedRequestId(requestId)
        let responseURL = queueBaseURL
            .appending(path: endpoint)
            .appending(path: "requests")
            .appending(path: requestId)
        return FALQueueSubmission(
            requestId: requestId,
            statusURL: responseURL.appending(path: "status"),
            responseURL: responseURL,
            cancelURL: responseURL.appending(path: "cancel")
        )
    }

    static func validatedEndpoint(_ endpoint: String) throws -> String {
        let components = endpoint.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard components.count >= 2,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw FALClientError.invalidEndpoint
        }
        return components.joined(separator: "/")
    }

    private static func validatedRequestId(_ requestId: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !requestId.isEmpty,
              requestId != ".",
              requestId != "..",
              requestId.unicodeScalars.allSatisfy(allowed.contains) else {
            throw FALClientError.invalidResponse
        }
        return requestId
    }
}

actor FALQueueClient {
    private let session: URLSession
    private let credentials: any FALCredentialProviding

    init(
        session: URLSession = .shared,
        credentials: any FALCredentialProviding = FALKeychainCredentialProvider()
    ) {
        self.session = session
        self.credentials = credentials
    }

    func submit(endpoint: String, input: [String: FALJSONValue]) async throws -> FALQueueSubmission {
        let apiKey = try await credentials.apiKey()
        let request = try FALQueueRequestBuilder.submitRequest(
            endpoint: endpoint,
            input: input,
            apiKey: apiKey
        )
        return try await perform(request, as: FALQueueSubmission.self)
    }

    func status(for submission: FALQueueSubmission) async throws -> FALQueueStatus {
        let apiKey = try await credentials.apiKey()
        return try await status(for: submission, apiKey: apiKey)
    }

    func result(for submission: FALQueueSubmission) async throws -> FALJSONValue {
        let apiKey = try await credentials.apiKey()
        return try await result(for: submission, apiKey: apiKey)
    }

    func waitForResult(
        _ submission: FALQueueSubmission,
        maximumPollCount: Int = 1_800
    ) async throws -> FALJSONValue {
        let apiKey = try await credentials.apiKey()
        do {
            for _ in 0..<maximumPollCount {
                try Task.checkCancellation()
                let current = try await status(for: submission, apiKey: apiKey)
                if current.status == .completed {
                    return try await result(for: submission, apiKey: apiKey)
                }
                try await Task.sleep(for: .seconds(1))
            }
            try await cancel(submission, apiKey: apiKey)
            throw FALImageGenerationError.timedOut
        } catch is CancellationError {
            try? await cancel(submission, apiKey: apiKey)
            throw CancellationError()
        }
    }

    func cancel(_ submission: FALQueueSubmission) async throws {
        let apiKey = try await credentials.apiKey()
        try await cancel(submission, apiKey: apiKey)
    }

    private func status(
        for submission: FALQueueSubmission,
        apiKey: String
    ) async throws -> FALQueueStatus {
        let request = try FALQueueRequestBuilder.authenticatedRequest(
            url: submission.statusURL,
            method: "GET",
            apiKey: apiKey
        )
        return try await perform(request, as: FALQueueStatus.self)
    }

    private func result(
        for submission: FALQueueSubmission,
        apiKey: String
    ) async throws -> FALJSONValue {
        let request = try FALQueueRequestBuilder.authenticatedRequest(
            url: submission.responseURL,
            method: "GET",
            apiKey: apiKey
        )
        return try await perform(request, as: FALJSONValue.self)
    }

    private func cancel(_ submission: FALQueueSubmission, apiKey: String) async throws {
        let request = try FALQueueRequestBuilder.authenticatedRequest(
            url: submission.cancelURL,
            method: "PUT",
            apiKey: apiKey
        )
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private func perform<Value: Decodable>(_ request: URLRequest, as type: Value.Type) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FALClientError.invalidResponse
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw FALClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FALClientError.httpStatus(response.statusCode)
        }
    }
}
