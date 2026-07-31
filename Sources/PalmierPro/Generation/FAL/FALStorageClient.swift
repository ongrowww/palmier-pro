import Foundation

struct FALStorageFile: Sendable {
    let url: URL
    let contentType: String
}

private struct FALStorageInitiation: Decodable {
    let fileURL: URL
    let uploadURL: URL

    enum CodingKeys: String, CodingKey {
        case fileURL = "file_url"
        case uploadURL = "upload_url"
    }
}

struct FALMultipartPart: Codable {
    let partNumber: Int
    let etag: String
}

enum FALStorageError: LocalizedError, Equatable {
    case unreadableFile(String)
    case invalidUploadURL
    case invalidFileURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let name): "Could not read \(name) for fal.ai upload."
        case .invalidUploadURL: "fal.ai returned an invalid upload URL."
        case .invalidFileURL: "fal.ai returned an invalid file URL."
        case .invalidResponse: "fal.ai returned an invalid storage response."
        case .httpStatus(let status): "fal.ai storage request failed (HTTP \(status))."
        }
    }
}

struct FALStorageRequestBuilder {
    private static let initiateURL = URL(
        string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"
    )!

    static func initiateRequest(
        fileName: String,
        contentType: String,
        apiKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: initiateURL)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            #"{"expiration_duration_seconds":86400}"#,
            forHTTPHeaderField: "X-Fal-Object-Lifecycle"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_type": contentType,
            "file_name": fileName,
        ])
        return request
    }

    static func multipartInitiateRequest(
        fileName: String,
        contentType: String,
        apiKey: String
    ) throws -> URLRequest {
        let url = URL(
            string: "https://rest.fal.ai/storage/upload/initiate-multipart?storage_type=fal-cdn-v3"
        )!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            #"{"expiration_duration_seconds":86400}"#,
            forHTTPHeaderField: "X-Fal-Object-Lifecycle"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_type": contentType,
            "file_name": fileName,
        ])
        return request
    }

    static func uploadRequest(url: URL, contentType: String) throws -> URLRequest {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw FALStorageError.invalidUploadURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    static func multipartPartRequest(
        uploadURL: URL,
        partNumber: Int,
        contentType: String
    ) throws -> URLRequest {
        try uploadRequest(
            url: try appendingPathComponent("\(partNumber)", to: uploadURL),
            contentType: contentType
        )
    }

    static func multipartCompleteRequest(
        uploadURL: URL,
        parts: [FALMultipartPart]
    ) throws -> URLRequest {
        let url = try appendingPathComponent("complete", to: uploadURL)
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw FALStorageError.invalidUploadURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["parts": parts])
        return request
    }

    private static func appendingPathComponent(_ component: String, to url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            throw FALStorageError.invalidUploadURL
        }
        components.path += components.path.hasSuffix("/") ? component : "/\(component)"
        guard let result = components.url else {
            throw FALStorageError.invalidUploadURL
        }
        return result
    }

    static func validatedFileURL(_ url: URL) throws -> URL {
        guard url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "fal.media" || host.hasSuffix(".fal.media"),
              url.user == nil,
              url.password == nil else {
            throw FALStorageError.invalidFileURL
        }
        return url
    }
}

actor FALStorageClient {
    private static let multipartThreshold = 90 * 1024 * 1024
    private static let multipartChunkSize = 10 * 1024 * 1024
    private let session: URLSession
    private let credentials: any FALCredentialProviding

    init(
        session: URLSession = .shared,
        credentials: any FALCredentialProviding = FALKeychainCredentialProvider()
    ) {
        self.session = session
        self.credentials = credentials
    }

    func upload(_ files: [FALStorageFile]) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let apiKey = try await credentials.apiKey()
        var results: [String] = []
        results.reserveCapacity(files.count)
        for file in files {
            try Task.checkCancellation()
            results.append(try await upload(file, apiKey: apiKey))
        }
        return results
    }

    private func upload(_ file: FALStorageFile, apiKey: String) async throws -> String {
        guard FileManager.default.isReadableFile(atPath: file.url.path) else {
            throw FALStorageError.unreadableFile(file.url.lastPathComponent)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let isMultipart = size > Self.multipartThreshold
        let initiate = try isMultipart
            ? FALStorageRequestBuilder.multipartInitiateRequest(
                fileName: file.url.lastPathComponent,
                contentType: file.contentType,
                apiKey: apiKey
            )
            : FALStorageRequestBuilder.initiateRequest(
                fileName: file.url.lastPathComponent,
                contentType: file.contentType,
                apiKey: apiKey
            )
        let (initiationData, initiationResponse) = try await session.data(for: initiate)
        try Self.validate(initiationResponse)
        guard let response = try? JSONDecoder().decode(
            FALStorageInitiation.self,
            from: initiationData
        ) else {
            throw FALStorageError.invalidResponse
        }
        let fileURL = try FALStorageRequestBuilder.validatedFileURL(response.fileURL)
        if isMultipart {
            try await uploadMultipart(
                file,
                uploadURL: response.uploadURL
            )
        } else {
            let uploadRequest = try FALStorageRequestBuilder.uploadRequest(
                url: response.uploadURL,
                contentType: file.contentType
            )
            let (_, uploadResponse) = try await session.upload(
                for: uploadRequest,
                fromFile: file.url
            )
            try Self.validate(uploadResponse)
        }
        return fileURL.absoluteString
    }

    private func uploadMultipart(
        _ file: FALStorageFile,
        uploadURL: URL
    ) async throws {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var parts: [FALMultipartPart] = []
        var partNumber = 1

        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: Self.multipartChunkSize) ?? Data()
            guard !data.isEmpty else { break }
            let request = try FALStorageRequestBuilder.multipartPartRequest(
                uploadURL: uploadURL,
                partNumber: partNumber,
                contentType: file.contentType
            )
            let (responseData, response) = try await session.upload(for: request, from: data)
            try Self.validate(response)
            guard let part = try? JSONDecoder().decode(
                FALMultipartPart.self,
                from: responseData
            ) else {
                throw FALStorageError.invalidResponse
            }
            parts.append(part)
            partNumber += 1
        }

        let complete = try FALStorageRequestBuilder.multipartCompleteRequest(
            uploadURL: uploadURL,
            parts: parts
        )
        let (_, response) = try await session.data(for: complete)
        try Self.validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw FALStorageError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FALStorageError.httpStatus(response.statusCode)
        }
    }
}
