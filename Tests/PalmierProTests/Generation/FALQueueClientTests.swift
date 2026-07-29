import Foundation
import Testing
@testable import PalmierPro

@Suite("FAL queue client")
struct FALQueueClientTests {
    @Test func buildsAuthenticatedQueueSubmissionRequest() throws {
        let request = try FALQueueRequestBuilder.submitRequest(
            endpoint: "fal-ai/nano-banana-2",
            input: [
                "prompt": .string("A quiet test frame"),
                "num_images": .number(1),
            ],
            apiKey: "test-key"
        )

        #expect(request.url?.absoluteString == "https://queue.fal.run/fal-ai/nano-banana-2")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Key test-key")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["prompt"] as? String == "A quiet test frame")
        #expect(json["num_images"] as? Double == 1)
    }

    @Test func rejectsExternalAndMalformedEndpoints() {
        #expect(throws: FALClientError.invalidEndpoint) {
            try FALQueueRequestBuilder.submitRequest(
                endpoint: "https://example.com/model",
                input: [:],
                apiKey: "test-key"
            )
        }
        #expect(throws: FALClientError.invalidEndpoint) {
            try FALQueueRequestBuilder.submitRequest(
                endpoint: "../model",
                input: [:],
                apiKey: "test-key"
            )
        }
    }

    @Test func acceptsOnlyFalQueueResponseURLs() throws {
        let trusted = try #require(URL(string: "https://queue.fal.run/fal-ai/model/requests/123/status"))
        let request = try FALQueueRequestBuilder.authenticatedRequest(
            url: trusted,
            method: "GET",
            apiKey: "test-key"
        )
        #expect(request.url == trusted)

        let external = try #require(URL(string: "https://example.com/requests/123/status"))
        #expect(throws: FALClientError.untrustedResponseURL) {
            try FALQueueRequestBuilder.authenticatedRequest(
                url: external,
                method: "GET",
                apiKey: "test-key"
            )
        }

        let alternatePort = try #require(URL(string: "https://queue.fal.run:444/requests/123/status"))
        #expect(throws: FALClientError.untrustedResponseURL) {
            try FALQueueRequestBuilder.authenticatedRequest(
                url: alternatePort,
                method: "GET",
                apiKey: "test-key"
            )
        }
    }

    @Test func decodesQueueMetadata() throws {
        let data = Data("""
        {
          "request_id": "req-123",
          "status_url": "https://queue.fal.run/fal-ai/model/requests/req-123/status",
          "response_url": "https://queue.fal.run/fal-ai/model/requests/req-123",
          "cancel_url": "https://queue.fal.run/fal-ai/model/requests/req-123/cancel"
        }
        """.utf8)

        let submission = try JSONDecoder().decode(FALQueueSubmission.self, from: data)
        #expect(submission.requestId == "req-123")
        #expect(submission.statusURL.host == "queue.fal.run")
    }

    @Test func reconstructsTrustedQueueMetadataForResume() throws {
        let submission = try FALQueueRequestBuilder.submission(
            endpoint: "fal-ai/nano-banana-2",
            requestId: "req-123"
        )

        #expect(submission.statusURL.absoluteString
            == "https://queue.fal.run/fal-ai/nano-banana-2/requests/req-123/status")
        #expect(submission.responseURL.absoluteString
            == "https://queue.fal.run/fal-ai/nano-banana-2/requests/req-123")
        #expect(throws: FALClientError.invalidResponse) {
            try FALQueueRequestBuilder.submission(
                endpoint: "fal-ai/nano-banana-2",
                requestId: "../outside"
            )
        }
    }
}
