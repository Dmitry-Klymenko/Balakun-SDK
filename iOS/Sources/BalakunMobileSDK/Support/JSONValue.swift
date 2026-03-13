import Foundation

/// Lossless JSON value wrapper for mixed payload sections.
public enum BalakunJSONValue: Equatable, Codable, Sendable {
    case object([String: BalakunJSONValue])
    case array([BalakunJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: BalakunJSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([BalakunJSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let string):
            try container.encode(string)
        case .number(let number):
            try container.encode(number)
        case .bool(let bool):
            try container.encode(bool)
        case .null:
            try container.encodeNil()
        }
    }

    static func fromAny(_ value: Any) -> BalakunJSONValue? {
        switch value {
        case let stringValue as String:
            return .string(stringValue)
        case let numberValue as NSNumber:
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return .bool(numberValue.boolValue)
            }
            return .number(numberValue.doubleValue)
        case let objectValue as [String: Any]:
            var object: [String: BalakunJSONValue] = [:]
            for (key, item) in objectValue {
                guard let converted = BalakunJSONValue.fromAny(item) else {
                    continue
                }
                object[key] = converted
            }
            return .object(object)
        case let arrayValue as [Any]:
            return .array(arrayValue.compactMap { BalakunJSONValue.fromAny($0) })
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}
