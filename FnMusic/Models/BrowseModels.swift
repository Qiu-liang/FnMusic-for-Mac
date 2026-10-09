import Foundation
import CryptoKit

/// Preserves JSON fields and structure for an entity whose nonempty wire model is unverified.
/// Numbers use Decimal instead of Double to avoid rounding integer identifiers.
indirect enum BrowseJSONValue: Codable, Equatable, Sendable {
    case object([String: BrowseJSONValue])
    case array([BrowseJSONValue])
    case string(String)
    case number(Decimal)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: BrowseJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([BrowseJSONValue].self) { self = .array(value) }
        else { self = .number(try container.decode(Decimal.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct GenreRecord: Codable, Identifiable, Hashable, Sendable {
    let rawValue: BrowseJSONValue
    /// UI identity only. Never send this fingerprint as an API guid.
    let id: String

    init(from decoder: Decoder) throws {
        rawValue = try BrowseJSONValue(from: decoder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonicalJSON = try encoder.encode(rawValue)
        id = SHA256.hash(data: canonicalJSON).map { String(format: "%02x", $0) }.joined()
    }

    func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var fields: [String: BrowseJSONValue]? {
        guard case .object(let fields) = rawValue else { return nil }
        return fields
    }

    /// Only a nonempty string actually returned by the server can navigate.
    var guid: String? {
        guard case .string(let guid) = fields?["guid"],
              !guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return guid
    }

    var displayName: String {
        guard case .string(let name) = fields?["name"],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未命名风格" }
        return name
    }
}

/// Read-only documented shared-library fields. No inferred access-status enum.
struct SharedLibrary: Codable, Identifiable, Sendable {
    let guid: String
    var name: String?
    /// Server-local path: display as text only, never construct a URL from it.
    var path: String?
    var autoDownloadLyric: Bool?
    var metadataPreference: String?
    var contentLastChangedAt: JSONScalar?
    var accessStatus: JSONScalar?

    var id: String { guid }
    var displayName: String { name?.nilIfEmpty ?? "未命名共享音乐库" }
}
