import Foundation
import Testing
@testable import PalmierPro

@Suite("Codex protocol")
struct CodexProtocolTests {
    @Test func lineBufferHandlesSplitAndMultipleMessages() {
        var buffer = CodexLineBuffer()

        #expect(buffer.append(Data(#"{"id":1"#.utf8)).isEmpty)
        let first = buffer.append(Data("}\n{\"id\":2}\n".utf8))

        #expect(first.count == 2)
        #expect(String(data: first[0], encoding: .utf8) == #"{"id":1}"#)
        #expect(String(data: first[1], encoding: .utf8) == #"{"id":2}"#)
    }

    @Test func rpcEnvelopeRoundTripsUnknownPayloadFields() throws {
        let data = Data("""
        {"id":"request-a","method":"future/event","params":{"known":true,"future":{"nested":1}}}
        """.utf8)

        let envelope = try JSONDecoder().decode(CodexRPCEnvelope.self, from: data)

        #expect(envelope.id == .string("request-a"))
        #expect(envelope.method == "future/event")
        #expect(envelope.params?["known"]?.boolValue == true)
        #expect(envelope.params?["future"]?["nested"] == .number(1))
    }

    @Test func foundationBridgePreservesJSONKinds() throws {
        let value = try CodexJSON.fromFoundation([
            "enabled": true,
            "count": 4,
            "ratio": 1.5,
            "names": ["one", "two"],
            "empty": NSNull(),
        ])
        let object = try #require(value.objectValue)

        #expect(object["enabled"] == .bool(true))
        #expect(object["count"] == .number(4))
        #expect(object["ratio"] == .number(1.5))
        #expect(object["names"] == .array([.string("one"), .string("two")]))
        #expect(object["empty"] == .null)
    }

    @Test func environmentAllowlistExcludesCredentials() {
        let environment = CodexExecutableLocator.allowedEnvironment(from: [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "CODEX_HOME": "/Users/test/.codex",
            "FAL_KEY": "secret",
            "ANTHROPIC_API_KEY": "secret",
            "UNRELATED_TOKEN": "secret",
        ])

        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["CODEX_HOME"] == "/Users/test/.codex")
        #expect(environment["FAL_KEY"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["UNRELATED_TOKEN"] == nil)
    }

    @Test func executableLocatorHonorsOverrideThenPathThenFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-locator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let override = root.appendingPathComponent("override-codex")
        let pathDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let pathExecutable = pathDirectory.appendingPathComponent("codex")
        let fallback = root.appendingPathComponent(".local/bin/codex")
        try makeExecutable(at: override)
        try makeExecutable(at: pathExecutable)
        try makeExecutable(at: fallback)

        let overrideResult = CodexExecutableLocator.locate(
            overrideURL: override,
            environment: ["PATH": pathDirectory.path],
            homeDirectory: root
        )
        #expect(overrideResult.url == override.standardizedFileURL)
        #expect(overrideResult.source == .override)

        let pathResult = CodexExecutableLocator.locate(
            overrideURL: nil,
            environment: ["PATH": pathDirectory.path],
            homeDirectory: root
        )
        #expect(pathResult.url == pathExecutable.standardizedFileURL)
        #expect(pathResult.source == .path)

        try FileManager.default.removeItem(at: pathExecutable)
        let fallbackResult = CodexExecutableLocator.locate(
            overrideURL: nil,
            environment: ["PATH": pathDirectory.path],
            homeDirectory: root
        )
        #expect(fallbackResult.url == fallback.standardizedFileURL)
        #expect(fallbackResult.source == .fallback)
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

