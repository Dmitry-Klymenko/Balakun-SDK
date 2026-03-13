import Foundation

extension BalakunEventDecoder {
    static func parseJSONObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8), !data.isEmpty else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func coerceInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }

            let doubleValue = number.doubleValue
            guard doubleValue.isFinite,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  doubleValue >= Double(Int.min),
                  doubleValue <= Double(Int.max) else {
                return nil
            }
            return Int(doubleValue)
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func coerceBool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }

            let doubleValue = number.doubleValue
            if doubleValue == 0 {
                return false
            }
            if doubleValue == 1 {
                return true
            }
            return nil
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(normalized) {
                return true
            }
            if ["false", "0", "no"].contains(normalized) {
                return false
            }
            return nil
        default:
            return nil
        }
    }

    static func coerceToolStats(_ value: Any?) -> [BalakunToolStat] {
        guard let rawTools = value as? [Any] else {
            return []
        }

        return rawTools.compactMap { entry in
            guard let record = entry as? [String: Any] else {
                return nil
            }
            guard let name = (record["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return nil
            }
            guard let isSuccessful = coerceBool(record["ok"]) else {
                return nil
            }
            let error = (record["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BalakunToolStat(name: name, ok: isSuccessful, error: error?.isEmpty == true ? nil : error)
        }
    }

    static func coerceProductsPayload(_ payload: [String: Any], fallbackAction: String) -> [String: Any]? {
        let rawItems = (payload["items"] as? [Any]) ?? (payload["products"] as? [Any]) ?? []
        guard !rawItems.isEmpty else {
            return nil
        }

        let normalizedItems = rawItems.compactMap(normalizeProductItem)

        guard !normalizedItems.isEmpty else {
            return nil
        }

        var normalizedPayload: [String: Any] = [
            "action": normalizedOptionalString(payload["action"]) ?? fallbackAction,
            "items": normalizedItems
        ]
        assignOptionalString("mode", from: payload["mode"], to: &normalizedPayload)
        assignOptionalString("layout", from: payload["layout"], to: &normalizedPayload)
        assignOptionalString("reference_set_id", from: payload["reference_set_id"], to: &normalizedPayload)
        assignOptionalString("title", from: payload["title"], to: &normalizedPayload)
        assignOptionalString("subtitle", from: payload["subtitle"], to: &normalizedPayload)

        return normalizedPayload
    }

    private static func normalizeProductItem(_ entry: Any) -> [String: Any]? {
        guard let item = entry as? [String: Any] else {
            return nil
        }

        let name = normalizedOptionalString(item["name"])
            ?? normalizedOptionalString(item["title"])
            ?? normalizedOptionalString(item["product_name"])
        guard let name else {
            return nil
        }

        var normalized: [String: Any] = ["name": name]
        if let position = coerceInt(item["position"]) {
            normalized["position"] = position
        }
        if let id = normalizedOptionalString(item["id"]) {
            normalized["id"] = id
        }
        if let url = normalizedOptionalString(item["url"])
            ?? normalizedOptionalString(item["link"])
            ?? normalizedOptionalString(item["href"]) {
            normalized["url"] = url
        }

        let images = normalizedProductImages(from: item)
        if !images.isEmpty {
            normalized["images"] = images
        }

        return normalized
    }

    private static func normalizedProductImages(from item: [String: Any]) -> [String] {
        var images = coerceStringArray(item["images"]) ?? []
        if let image = normalizedOptionalString(item["image"]) {
            images.append(image)
        }
        return deduplicatedStrings(images)
    }

    private static func assignOptionalString(
        _ key: String,
        from sourceValue: Any?,
        to payload: inout [String: Any]
    ) {
        guard let value = normalizedOptionalString(sourceValue) else {
            return
        }
        payload[key] = value
    }

    static func parseUnknownPayload(_ string: String) -> BalakunJSONValue? {
        guard let data = string.data(using: .utf8), !data.isEmpty else {
            return nil
        }

        if let value = try? JSONSerialization.jsonObject(with: data),
           let converted = BalakunJSONValue.fromAny(value) {
            return converted
        }

        return .string(string)
    }

    static func coerceStringArray(_ value: Any?) -> [String]? {
        let values: [Any]
        switch value {
        case let array as [Any]:
            values = array
        case let string as String:
            values = [string]
        default:
            return nil
        }

        let normalized = values.compactMap { entry -> String? in
            guard let string = normalizedOptionalString(entry) else {
                return nil
            }
            return string
        }

        return normalized.isEmpty ? nil : normalized
    }

    static func deduplicatedStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    static func normalizedOptionalString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
