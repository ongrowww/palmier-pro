import Foundation

enum CodexJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSON])
    case object([String: CodexJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CodexJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: CodexJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: CodexJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [CodexJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> CodexJSON? { objectValue?[key] }

    func foundationObject() -> Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map { $0.foundationObject() }
        case .object(let values): values.mapValues { $0.foundationObject() }
        }
    }

    static func fromFoundation(_ value: Any) throws -> CodexJSON {
        switch value {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(try value.map(fromFoundation))
        case let value as [String: Any]: return .object(try value.mapValues(fromFoundation))
        default: throw CodexAppServerError.invalidJSON
        }
    }
}

enum CodexRPCID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

struct CodexRPCEnvelope: Codable, Sendable {
    let id: CodexRPCID?
    let method: String?
    let params: CodexJSON?
    let result: CodexJSON?
    let error: CodexRPCErrorPayload?

    init(
        id: CodexRPCID? = nil,
        method: String? = nil,
        params: CodexJSON? = nil,
        result: CodexJSON? = nil,
        error: CodexRPCErrorPayload? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case id, method, params, result, error
    }
}

struct CodexRPCErrorPayload: Codable, Sendable {
    let code: Int
    let message: String
}

struct CodexLineBuffer: Sendable {
    private var data = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[..<newline]
            data.removeSubrange(...newline)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}
