import Foundation

extension BalakunVoiceTagParser {
    static func stripSpeakAndAudioTags(_ text: String) -> String {
        var output = text
        let patterns = ["(?i)</?speak\\b[^>]*>", "(?i)</?audio\\b[^>]*>"]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            output = regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: ""
            )
        }

        return output
    }

    static func appendTextParts(from text: String, into parts: inout [BalakunSpeechPart]) {
        for item in buildTextAndBreakParts(from: text) {
            parts.append(item)
        }
    }

    static func buildTextAndBreakParts(from text: String) -> [BalakunSpeechPart] {
        let pattern = "(?i)<break\\b([^>]*)/?>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return normalizeTextPart(text).map { [.text($0)] } ?? []
        }

        var result: [BalakunSpeechPart] = []
        var searchStart = text.startIndex
        let fullRange = NSRange(text.startIndex..., in: text)

        for match in regex.matches(in: text, range: fullRange) {
            guard let matchRange = Range(match.range, in: text) else {
                continue
            }

            let head = String(text[searchStart..<matchRange.lowerBound])
            if let normalized = normalizeTextPart(head) {
                result.append(.text(normalized))
            }

            if match.numberOfRanges > 1,
               let attributeRange = Range(match.range(at: 1), in: text) {
                let attributes = parseAttributes(String(text[attributeRange]))
                if let milliseconds = parseBreakDurationMilliseconds(attrs: attributes), milliseconds > 0 {
                    result.append(.pause(milliseconds: milliseconds))
                }
            }

            searchStart = matchRange.upperBound
        }

        if searchStart < text.endIndex {
            let tail = String(text[searchStart...])
            if let normalized = normalizeTextPart(tail) {
                result.append(.text(normalized))
            }
        }

        return result
    }

    static func normalizeTextPart(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[*_~]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }
}
