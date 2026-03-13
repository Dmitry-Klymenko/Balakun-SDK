import Foundation

/// Normalized stream events emitted by `BalakunClient.sendMessage`.
public enum BalakunStreamEvent: Equatable, Sendable {
    case model(BalakunModelEvent)
    case answerDelta(BalakunAnswerDeltaEvent)
    case reasoningDelta(BalakunReasoningDeltaEvent)
    case tag(BalakunTagEvent)
    case tool(BalakunToolEvent)
    case products(BalakunProductsEvent)
    case navigate(BalakunNavigateEvent)
    case clientState(BalakunClientStateEvent)
    case toolingStats(BalakunToolingStatsEvent)
    case logEvent(BalakunLogEvent)
    case addToBasket(BalakunAddToBasketEvent)
    case submitForm(BalakunSubmitFormEvent)
    case conversationMeaningful(BalakunConversationMeaningfulEvent)
    case done(BalakunDoneEvent)
    case error(BalakunErrorEvent)
    case unknown(BalakunUnknownEvent)
}

public struct BalakunModelEvent: Codable, Equatable, Sendable {
    public var model: String
    public var queryLanguageTag: String?
    public var languageConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case queryLanguageTag = "query_language_tag"
        case languageConfidence = "language_confidence"
    }
}

public struct BalakunAnswerDeltaEvent: Codable, Equatable, Sendable {
    public var content: String
    public var messageID: String?

    enum CodingKeys: String, CodingKey {
        case content
        case messageID = "messageId"
    }
}

public struct BalakunReasoningDeltaEvent: Codable, Equatable, Sendable {
    public var content: String
}

public struct BalakunTagEvent: Codable, Equatable, Sendable {
    public var tag: String
    public var attributes: [String: String]?
    public var content: String?

    enum CodingKeys: String, CodingKey {
        case tag
        case attributes = "attrs"
        case content
    }
}

public struct BalakunToolEvent: Codable, Equatable, Sendable {
    public var tool: String
    public var args: [String: BalakunJSONValue]?
    public var raw: String?
}

public struct BalakunProductsEvent: Codable, Equatable, Sendable {
    public var action: String
    public var mode: String?
    public var layout: String?
    public var referenceSetID: String?
    public var title: String?
    public var subtitle: String?
    public var items: [BalakunProductItem]
    public var memory: BalakunRecommendationMemory?

    enum CodingKeys: String, CodingKey {
        case action
        case mode
        case layout
        case referenceSetID = "reference_set_id"
        case title
        case subtitle
        case items
        case memory
    }
}

public struct BalakunProductItem: Codable, Equatable, Sendable {
    public var position: Int?
    public var id: String?
    public var name: String
    public var url: String?
    public var images: [String]?

    public init(
        position: Int? = nil,
        id: String? = nil,
        name: String,
        url: String? = nil,
        images: [String]? = nil
    ) {
        self.position = position
        self.id = id
        self.name = name
        self.url = url
        self.images = images
    }
}

public struct BalakunNavigateEvent: Codable, Equatable, Sendable {
    public var action: String
    public var url: String
    public var mode: String?
    public var reason: String?
}

public struct BalakunClientStateEvent: Codable, Equatable, Sendable {
    public var action: String
    public var commands: [BalakunClientStateCommand]
}

public struct BalakunClientStateCommand: Codable, Equatable, Sendable {
    public var op: String
    public var key: String
    public var scope: String?
    public var value: BalakunJSONValue?
    public var reason: String?
}

public struct BalakunToolingStatsEvent: Codable, Equatable, Sendable {
    public var llmCalls: Int?
    public var tools: [BalakunToolStat]

    enum CodingKeys: String, CodingKey {
        case llmCalls = "llm_calls"
        case tools
    }
}

public struct BalakunToolStat: Codable, Equatable, Sendable {
    public var name: String
    public var ok: Bool
    public var error: String?
}

public struct BalakunLogEvent: Codable, Equatable, Sendable {
    public var eventName: String
    public var severity: String?
    public var properties: [String: BalakunJSONValue]?

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case severity
        case properties
    }
}

public struct BalakunAddToBasketEvent: Codable, Equatable, Sendable {
    public var action: String
    public var ok: Bool?
    public var source: String?
    public var position: Int?
    public var url: String?
}

public struct BalakunSubmitFormEvent: Codable, Equatable, Sendable {
    public var tool: String?
    public var ok: Bool?
    public var messageID: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case tool
        case ok
        case messageID = "messageId"
        case error
    }
}

public struct BalakunConversationMeaningfulEvent: Codable, Equatable, Sendable {
    public var reason: String
}

public struct BalakunDoneEvent: Codable, Equatable, Sendable {
    public var messageID: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
    }
}

public struct BalakunErrorEvent: Codable, Equatable, Sendable {
    public var error: String
    public var status: Int?
}

public struct BalakunUnknownEvent: Equatable, Sendable {
    public var name: String
    public var payload: BalakunJSONValue?
}
