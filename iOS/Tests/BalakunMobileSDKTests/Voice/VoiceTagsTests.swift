import XCTest
@testable import BalakunMobileSDK

/// Unit tests for voice-tag parser behavior.
final class VoiceTagsTests: XCTestCase {
    /// Verifies parser extracts audio metadata and break duration when audio parsing is enabled.
    func testParsesAudioAndBreakTags() {
        let input = "Hello <speak>listen <audio src=\"https://example.com/a.mp3\">fallback</audio></speak> <break time=\"500ms\"/> now"
        let parsed = BalakunVoiceTagParser.parseMessageContent(input, audioTagProcessingEnabled: true)

        XCTAssertTrue(parsed.displayMarkdown.contains("Hello"))
        XCTAssertTrue(parsed.displayMarkdown.contains("fallback"))

        let audioPart = parsed.speechParts.first {
            if case .audio = $0 { return true }
            return false
        }

        guard case .audio(let audioSegment)? = audioPart else {
            XCTFail("Expected audio segment")
            return
        }

        XCTAssertEqual(audioSegment.sourceURL, "https://example.com/a.mp3")
        XCTAssertEqual(audioSegment.spokenText, "fallback")

        let pausePart = parsed.speechParts.first {
            if case .pause = $0 { return true }
            return false
        }

        guard case .pause(let milliseconds)? = pausePart else {
            XCTFail("Expected pause segment")
            return
        }
        XCTAssertEqual(milliseconds, 500)
    }

    /// Verifies parser removes speech/audio wrapper tags when audio parsing is disabled.
    func testStripsTagsWhenAudioProcessingDisabled() {
        let input = "Hello <speak>there</speak> <audio>friend</audio>"
        let parsed = BalakunVoiceTagParser.parseMessageContent(input, audioTagProcessingEnabled: false)
        XCTAssertFalse(parsed.displayMarkdown.contains("<speak>"))
        XCTAssertFalse(parsed.displayMarkdown.contains("</speak>"))
        XCTAssertFalse(parsed.displayMarkdown.contains("<audio>"))
        XCTAssertFalse(parsed.displayMarkdown.contains("</audio>"))

        let allText = parsed.speechParts.compactMap { part -> String? in
            if case .text(let value) = part {
                return value
            }
            return nil
        }.joined(separator: " ")

        XCTAssertTrue(allText.contains("Hello"))
        XCTAssertTrue(allText.contains("there"))
        XCTAssertTrue(allText.contains("friend"))
    }

    /// Verifies tagged-only extraction excludes plain text parts.
    func testExtractTaggedSpeechPartsExcludesText() {
        let input = "Start <audio src=\"https://example.com/a.mp3\">fallback</audio> middle <break time=\"250ms\"/> end"
        let parts = BalakunVoiceTagParser.extractTaggedSpeechParts(input, audioTagProcessingEnabled: true)

        XCTAssertEqual(parts.count, 2)

        guard case .audio(let segment) = parts[0] else {
            XCTFail("Expected first tagged part to be audio")
            return
        }
        XCTAssertEqual(segment.sourceURL, "https://example.com/a.mp3")
        XCTAssertEqual(segment.spokenText, "fallback")

        guard case .pause(let milliseconds) = parts[1] else {
            XCTFail("Expected second tagged part to be pause")
            return
        }
        XCTAssertEqual(milliseconds, 250)
    }

    /// Verifies parser reads JSON audio artifact timing and clock-style break durations.
    func testParsesAudioArtifactJSONAndClockBreak() {
        let input = """
        <audio audio_artifact='{"url":"https://cdn.example.com/clip.mp3","start":"00:01","end":"00:02.5"}'>fallback text</audio>
        <break time="00:00:01.250"/>
        """
        let parsed = BalakunVoiceTagParser.parseMessageContent(input, audioTagProcessingEnabled: true)

        let audioPart = parsed.speechParts.first {
            if case .audio = $0 { return true }
            return false
        }

        guard case .audio(let segment)? = audioPart else {
            XCTFail("Expected audio segment")
            return
        }

        XCTAssertEqual(segment.sourceURL, "https://cdn.example.com/clip.mp3")
        XCTAssertEqual(segment.spokenText, "fallback text")
        guard let timing = segment.timing else {
            XCTFail("Expected timing metadata")
            return
        }
        XCTAssertEqual(timing.startSeconds ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(timing.endSeconds ?? -1, 2.5, accuracy: 0.0001)

        let pausePart = parsed.speechParts.first {
            if case .pause = $0 { return true }
            return false
        }

        guard case .pause(let milliseconds)? = pausePart else {
            XCTFail("Expected pause segment")
            return
        }
        XCTAssertEqual(milliseconds, 1250)
    }
}
