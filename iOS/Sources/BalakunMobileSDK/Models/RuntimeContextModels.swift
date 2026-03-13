import Foundation

public struct BalakunRuntimeContext: Codable, Equatable, Sendable {
    public var pageURL: String?
    public var screenName: String?
    public var pagePath: String?
    public var pageTitle: String?
    public var referrer: String?
    public var locale: String?
    public var device: String?
    public var selectedText: String?
    public var activeSection: String?
    public var domAnchor: String?
    public var visibleCTAs: [BalakunVisibleCTA]?
    public var utm: BalakunUTM?
    public var consentState: String?
    public var uiCapabilities: [String: Bool]?
    public var lastRecommendations: BalakunRecommendationMemory?
    public var retailState: BalakunRetailState?

    public init(
        pageURL: String? = nil,
        screenName: String? = nil,
        pagePath: String? = nil,
        pageTitle: String? = nil,
        referrer: String? = nil,
        locale: String? = nil,
        device: String? = nil,
        selectedText: String? = nil,
        activeSection: String? = nil,
        domAnchor: String? = nil,
        visibleCTAs: [BalakunVisibleCTA]? = nil,
        utm: BalakunUTM? = nil,
        consentState: String? = nil,
        uiCapabilities: [String: Bool]? = nil,
        lastRecommendations: BalakunRecommendationMemory? = nil,
        retailState: BalakunRetailState? = nil
    ) {
        self.pageURL = pageURL
        self.screenName = screenName
        self.pagePath = pagePath
        self.pageTitle = pageTitle
        self.referrer = referrer
        self.locale = locale
        self.device = device
        self.selectedText = selectedText
        self.activeSection = activeSection
        self.domAnchor = domAnchor
        self.visibleCTAs = visibleCTAs
        self.utm = utm
        self.consentState = consentState
        self.uiCapabilities = uiCapabilities
        self.lastRecommendations = lastRecommendations
        self.retailState = retailState
    }
}

public struct BalakunVisibleCTA: Codable, Equatable, Sendable {
    public var label: String
    public var href: String

    public init(label: String, href: String) {
        self.label = label
        self.href = href
    }
}

public struct BalakunUTM: Codable, Equatable, Sendable {
    public var source: String?
    public var medium: String?
    public var campaign: String?
    public var term: String?
    public var content: String?

    public init(source: String? = nil, medium: String? = nil, campaign: String? = nil, term: String? = nil, content: String? = nil) {
        self.source = source
        self.medium = medium
        self.campaign = campaign
        self.term = term
        self.content = content
    }
}

public struct BalakunRecommendationMemory: Codable, Equatable, Sendable {
    public var referenceSetID: String?
    public var items: [BalakunRecommendationItem]

    public init(referenceSetID: String? = nil, items: [BalakunRecommendationItem]) {
        self.referenceSetID = referenceSetID
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case referenceSetID = "reference_set_id"
        case items
    }
}

public struct BalakunRecommendationItem: Codable, Equatable, Sendable {
    public var position: Int?
    public var name: String?
    public var url: String

    public init(position: Int? = nil, name: String? = nil, url: String) {
        self.position = position
        self.name = name
        self.url = url
    }
}

public struct BalakunRetailState: Codable, Equatable, Sendable {
    public var activeReferenceSetID: String?
    public var memorySessionID: String?
    public var memoryPageURL: String?
    public var memoryGeneratedAt: String?
    public var selectedProductURL: String?
    public var selectedPosition: Int?
    public var lastViewedCategory: String?
    public var filters: [String]?

    public init(
        activeReferenceSetID: String? = nil,
        memorySessionID: String? = nil,
        memoryPageURL: String? = nil,
        memoryGeneratedAt: String? = nil,
        selectedProductURL: String? = nil,
        selectedPosition: Int? = nil,
        lastViewedCategory: String? = nil,
        filters: [String]? = nil
    ) {
        self.activeReferenceSetID = activeReferenceSetID
        self.memorySessionID = memorySessionID
        self.memoryPageURL = memoryPageURL
        self.memoryGeneratedAt = memoryGeneratedAt
        self.selectedProductURL = selectedProductURL
        self.selectedPosition = selectedPosition
        self.lastViewedCategory = lastViewedCategory
        self.filters = filters
    }

    enum CodingKeys: String, CodingKey {
        case activeReferenceSetID = "active_reference_set_id"
        case memorySessionID = "memory_session_id"
        case memoryPageURL = "memory_page_url"
        case memoryGeneratedAt = "memory_generated_at"
        case selectedProductURL = "selected_product_url"
        case selectedPosition = "selected_position"
        case lastViewedCategory = "last_viewed_category"
        case filters
    }
}
