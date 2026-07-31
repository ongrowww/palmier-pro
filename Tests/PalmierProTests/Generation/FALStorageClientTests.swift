import Foundation
import Testing
@testable import PalmierPro

@Suite("FAL storage client")
struct FALStorageClientTests {
    @Test func buildsCurrentFalCDNUploadInitiation() throws {
        let request = try FALStorageRequestBuilder.initiateRequest(
            fileName: "reference.mov",
            contentType: "video/quicktime",
            apiKey: "test-key"
        )

        #expect(request.url?.absoluteString
            == "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Key test-key")
        #expect(request.value(forHTTPHeaderField: "X-Fal-Object-Lifecycle")
            == #"{"expiration_duration_seconds":86400}"#)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["file_name"] as? String == "reference.mov")
        #expect(json["content_type"] as? String == "video/quicktime")
    }

    @Test func preservesMultipartUploadQueryParameters() throws {
        let uploadURL = try #require(URL(
            string: "https://upload.example.com/files/object?uploadId=abc&signature=xyz"
        ))
        let part = try FALStorageRequestBuilder.multipartPartRequest(
            uploadURL: uploadURL,
            partNumber: 3,
            contentType: "video/mp4"
        )
        #expect(part.url?.path == "/files/object/3")
        #expect(part.url?.query == "uploadId=abc&signature=xyz")

        let complete = try FALStorageRequestBuilder.multipartCompleteRequest(
            uploadURL: uploadURL,
            parts: [FALMultipartPart(partNumber: 3, etag: "etag-3")]
        )
        #expect(complete.url?.path == "/files/object/complete")
        #expect(complete.url?.query == "uploadId=abc&signature=xyz")
        let body = try #require(complete.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parts = try #require(json["parts"] as? [[String: Any]])
        #expect(parts.first?["partNumber"] as? Int == 3)
        #expect(parts.first?["etag"] as? String == "etag-3")
    }

    @Test func acceptsOnlyFalHostedResultURLs() throws {
        let trusted = try #require(URL(string: "https://v3b.fal.media/files/a/video.mp4"))
        #expect(try FALStorageRequestBuilder.validatedFileURL(trusted) == trusted)

        let external = try #require(URL(string: "https://example.com/video.mp4"))
        #expect(throws: FALStorageError.invalidFileURL) {
            try FALStorageRequestBuilder.validatedFileURL(external)
        }
    }
}
