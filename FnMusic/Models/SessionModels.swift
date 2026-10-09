import Foundation

struct User: Codable, Hashable, Sendable {
    let guid: String
    var name: String?
    var role: String?
    var lastAccessedAt: Double?
    var createdAt: Double?
    var updatedAt: Double?
    var isAdministrator: Bool { role == "admin" }
}

struct SystemConfiguration: Codable, Sendable {
    var serverGUID: String?
    var serverName: String?
    var serverVersion: String?
    var mediasrvVersion: String?
    var capabilities: Capabilities?

    struct Capabilities: Codable, Sendable {
        var folderView: Bool?
        var libraryReconnect: Bool?
    }
}

/// System status fields have no documented complete enum/type contract.
/// Preserve their scalar representation rather than inventing entitlement rules.
enum JSONScalar: Codable, Sendable {
    case string(String), number(Double), boolean(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else { self = .number(try value.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .boolean(let flag): try value.encode(flag)
        case .null: try value.encodeNil()
        }
    }
    var display: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .boolean(let value): String(value)
        case .null: "—"
        }
    }
}

struct SystemInfo: Codable, Sendable {
    var connect: Connection?
    struct Connection: Codable, Sendable {
        var id: JSONScalar?
        var status: JSONScalar?
        var entitlement: Entitlement?
    }
    struct Entitlement: Codable, Sendable {
        var type: JSONScalar?
        var endTime: JSONScalar?
    }
}

struct InitializationState: Codable, Sendable {
    var initialized: Bool
}

struct LoginResponse: Codable, Sendable {
    var userToken: String
    var user: User
}

struct Lyric: Codable, Identifiable, Sendable {
    var guid: String
    var source: Int?
    var content: String?
    var createdAt: Double?
    var updatedAt: Double?
    var isLRC: Bool?
    var offset: Double?
    var id: String { guid }
}

struct LyricResponse: Codable, Sendable {
    var list: [Lyric]
    var preferred: String?
    var selected: Lyric? { list.first(where: { $0.guid == preferred }) ?? list.first }
}
