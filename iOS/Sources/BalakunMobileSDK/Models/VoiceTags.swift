import Foundation

public struct BalakunParsedSpeech: Equatable {
    public var displayMarkdown: String
    public var speechParts: [BalakunSpeechPart]

    public init(displayMarkdown: String, speechParts: [BalakunSpeechPart]) {
        self.displayMarkdown = displayMarkdown
        self.speechParts = speechParts
    }
}

public enum BalakunSpeechPart: Equatable {
    case text(String)
    case audio(BalakunAudioSegment)
    case pause(milliseconds: Int)
}

public struct BalakunAudioSegment: Equatable {
    public var sourceURL: String?
    public var spokenText: String?
    public var timing: BalakunAudioTiming?

    public init(sourceURL: String?, spokenText: String?, timing: BalakunAudioTiming?) {
        self.sourceURL = sourceURL
        self.spokenText = spokenText
        self.timing = timing
    }
}

public struct BalakunAudioTiming: Equatable {
    public var startSeconds: Double?
    public var endSeconds: Double?

    public init(startSeconds: Double?, endSeconds: Double?) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public enum BalakunVoiceTagParser {
    public static func parseMessageContent(
        _ input: String,
        audioTagProcessingEnabled: Bool
    ) -> BalakunParsedSpeech {
        if audioTagProcessingEnabled {
            return parseContentWithAudioTagsEnabled(input)
        }
        return parseContentWithAudioTagsDisabled(input)
    }

    public static func extractTaggedSpeechParts(
        _ input: String,
        audioTagProcessingEnabled: Bool
    ) -> [BalakunSpeechPart] {
        guard audioTagProcessingEnabled else {
            return []
        }

        return parseMessageContent(input, audioTagProcessingEnabled: true).speechParts.filter { part in
            switch part {
            case .audio, .pause:
                return true
            case .text:
                return false
            }
        }
    }
}
