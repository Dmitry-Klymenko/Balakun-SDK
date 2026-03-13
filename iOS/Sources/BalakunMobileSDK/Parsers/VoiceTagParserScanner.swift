import Foundation

extension BalakunVoiceTagParser {
    static func parseBreakDurationMilliseconds(attrs: [String: String]) -> Int? {
        guard let raw = attrs["time"], let seconds = parseTimeSeconds(raw) else {
            return nil
        }
        return max(Int(seconds * 1000.0), 0)
    }

    static func parseTimeSeconds(_ raw: String?) -> Double? {
        guard let raw else {
            return nil
        }

        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }

        if value.hasSuffix("ms"), let milliseconds = Double(value.dropLast(2)) {
            return milliseconds / 1000.0
        }

        if value.hasSuffix("s"), let seconds = Double(value.dropLast(1)) {
            return seconds
        }

        if value.contains(":") {
            let parts = value.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 {
                return parts[0] * 60 + parts[1]
            }
            if parts.count == 3 {
                return parts[0] * 3600 + parts[1] * 60 + parts[2]
            }
        }

        return Double(value)
    }

    static func parseTimeSeconds(any: Any?) -> Double? {
        switch any {
        case let value as String:
            return parseTimeSeconds(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    static func parseAttributes(_ raw: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }

        let fullRange = NSRange(raw.startIndex..., in: raw)
        var attributes: [String: String] = [:]

        for match in regex.matches(in: raw, range: fullRange) {
            guard match.numberOfRanges >= 6,
                  let keyRange = Range(match.range(at: 1), in: raw) else {
                continue
            }

            let key = String(raw[keyRange]).lowercased()
            let quotedDouble = Range(match.range(at: 3), in: raw).map { String(raw[$0]) }
            let quotedSingle = Range(match.range(at: 4), in: raw).map { String(raw[$0]) }
            let unquoted = Range(match.range(at: 5), in: raw).map { String(raw[$0]) }

            attributes[key] = quotedDouble ?? quotedSingle ?? unquoted ?? ""
        }

        return attributes
    }

    static func findClosingTag(_ name: String, in source: String, from start: String.Index) -> Range<String.Index>? {
        let needle = "</\(name)>"
        return source.range(of: needle, options: [.caseInsensitive], range: start..<source.endIndex)
    }

    static func scanTag(in source: String, from start: String.Index) -> ParsedTag? {
        guard source[start] == "<" else {
            return nil
        }

        var index = source.index(after: start)
        var isClosing = false

        if index < source.endIndex, source[index] == "/" {
            isClosing = true
            index = source.index(after: index)
        }

        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }

        let nameStart = index
        while index < source.endIndex,
              source[index].isLetter || source[index].isNumber || source[index] == "-" || source[index] == "_" {
            index = source.index(after: index)
        }

        guard nameStart < index else {
            return nil
        }

        let name = String(source[nameStart..<index]).lowercased()

        var quote: Character?
        var end = index
        while end < source.endIndex {
            let character = source[end]

            if quote == nil && (character == "\"" || character == "'") {
                quote = character
            } else if quote == character {
                quote = nil
            } else if quote == nil && character == ">" {
                let tagBody = String(source[index..<end])
                let attributes = isClosing ? [:] : parseAttributes(tagBody)
                let selfClosing = !isClosing
                    && tagBody.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
                let endIndex = source.index(after: end)

                return ParsedTag(
                    name: name,
                    attributes: attributes,
                    isClosing: isClosing,
                    selfClosing: selfClosing || name == "break",
                    startIndex: start,
                    endIndex: endIndex
                )
            }

            end = source.index(after: end)
        }

        return nil
    }
}

struct ParsedTag {
    let name: String
    let attributes: [String: String]
    let isClosing: Bool
    let selfClosing: Bool
    let startIndex: String.Index
    let endIndex: String.Index
}
