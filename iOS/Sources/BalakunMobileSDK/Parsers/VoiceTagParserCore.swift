import Foundation

extension BalakunVoiceTagParser {
    static func parseContentWithAudioTagsDisabled(_ input: String) -> BalakunParsedSpeech {
        let cleaned = stripSpeakAndAudioTags(input)
        return BalakunParsedSpeech(displayMarkdown: cleaned, speechParts: buildTextAndBreakParts(from: cleaned))
    }

    static func parseContentWithAudioTagsEnabled(_ input: String) -> BalakunParsedSpeech {
        var state = ParsedSpeechState()
        var cursor = input.startIndex

        while cursor < input.endIndex {
            guard let tagStart = input[cursor...].firstIndex(of: "<") else {
                appendPlainText(String(input[cursor...]), to: &state)
                break
            }

            if tagStart > cursor {
                appendPlainText(String(input[cursor..<tagStart]), to: &state)
            }

            guard let tag = scanTag(in: input, from: tagStart) else {
                appendPlainText(String(input[tagStart]), to: &state)
                cursor = input.index(after: tagStart)
                continue
            }

            cursor = tag.endIndex

            if shouldIgnoreTag(tag) {
                continue
            }

            if appendBreakPartIfNeeded(tag, to: &state) {
                continue
            }

            if handleAudioTag(tag, in: input, cursor: &cursor, state: &state) {
                continue
            }

            let literalTag = String(input[tag.startIndex..<tag.endIndex])
            appendPlainText(literalTag, to: &state)
        }

        return BalakunParsedSpeech(displayMarkdown: state.display, speechParts: state.parts)
    }

    private struct ParsedSpeechState {
        var display = ""
        var parts: [BalakunSpeechPart] = []
    }

    private static func appendPlainText(_ text: String, to state: inout ParsedSpeechState) {
        state.display += text
        appendTextParts(from: text, into: &state.parts)
    }

    private static func shouldIgnoreTag(_ tag: ParsedTag) -> Bool {
        tag.name == "speak"
    }

    private static func appendBreakPartIfNeeded(_ tag: ParsedTag, to state: inout ParsedSpeechState) -> Bool {
        guard tag.name == "break", !tag.isClosing else {
            return false
        }
        if let milliseconds = parseBreakDurationMilliseconds(attrs: tag.attributes), milliseconds > 0 {
            state.parts.append(.pause(milliseconds: milliseconds))
        }
        return true
    }

    private static func handleAudioTag(
        _ tag: ParsedTag,
        in input: String,
        cursor: inout String.Index,
        state: inout ParsedSpeechState
    ) -> Bool {
        guard tag.name == "audio", !tag.isClosing else {
            return false
        }

        if tag.selfClosing {
            appendAudioSegment(attributes: tag.attributes, innerText: nil, to: &state)
            return true
        }

        if let closeRange = findClosingTag("audio", in: input, from: cursor) {
            let inner = String(input[cursor..<closeRange.lowerBound])
            state.display += inner
            appendAudioSegment(attributes: tag.attributes, innerText: inner, to: &state)
            cursor = closeRange.upperBound
            return true
        }

        appendAudioSegment(attributes: tag.attributes, innerText: nil, to: &state)
        return true
    }

    private static func appendAudioSegment(
        attributes: [String: String],
        innerText: String?,
        to state: inout ParsedSpeechState
    ) {
        let segment = resolveAudioSegment(attributes: attributes, innerText: innerText)
        guard segment.sourceURL != nil || segment.spokenText != nil else {
            return
        }
        state.parts.append(.audio(segment))
    }

    static func resolveAudioSegment(attributes: [String: String], innerText: String?) -> BalakunAudioSegment {
        let artifact = attributes["audio_artifact"]
            ?? attributes["audio-artifact"]
            ?? attributes["audioartifact"]
            ?? attributes["src"]
            ?? attributes["url"]

        let spokenSource = attributes["spoken_text"]
            ?? attributes["spoken-text"]
            ?? attributes["spokentext"]
            ?? (innerText ?? "")
        let spoken = normalizeTextPart(spokenSource)

        var sourceURL = artifact
        var timing = parseTiming(attributes: attributes)

        if let artifact,
           artifact.hasPrefix("{") || artifact.hasPrefix("["),
           let data = artifact.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let resolvedURL = object["url"] as? String ?? object["src"] as? String {
                sourceURL = resolvedURL
            }
            if timing == nil {
                timing = parseTiming(fromObject: object)
            }
        }

        return BalakunAudioSegment(sourceURL: sourceURL, spokenText: spoken, timing: timing)
    }

    static func parseTiming(attributes: [String: String]) -> BalakunAudioTiming? {
        let start = parseTimeSeconds(
            attributes["clipbegin"]
            ?? attributes["begin"]
            ?? attributes["start"]
            ?? attributes["start-time"]
            ?? attributes["start_time"]
        )

        var end = parseTimeSeconds(
            attributes["clipend"]
            ?? attributes["end"]
            ?? attributes["finish"]
            ?? attributes["stop"]
            ?? attributes["end-time"]
            ?? attributes["end_time"]
        )

        if end == nil,
           let start,
           let duration = parseTimeSeconds(attributes["duration"]) {
            end = start + duration
        }

        if start == nil && end == nil {
            return nil
        }

        return BalakunAudioTiming(startSeconds: start, endSeconds: end)
    }

    static func parseTiming(fromObject object: [String: Any]) -> BalakunAudioTiming? {
        let start = parseTimeSeconds(any: object["start"] ?? object["clipbegin"])
        var end = parseTimeSeconds(any: object["end"] ?? object["clipend"])

        if end == nil,
           let start,
           let duration = parseTimeSeconds(any: object["duration"]) {
            end = start + duration
        }

        if start == nil && end == nil {
            return nil
        }

        return BalakunAudioTiming(startSeconds: start, endSeconds: end)
    }
}
