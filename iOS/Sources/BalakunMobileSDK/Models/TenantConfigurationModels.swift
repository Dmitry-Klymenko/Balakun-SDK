import Foundation

/// Public tenant configuration returned by `/t/{tenant}/config`.
public struct BalakunPublicTenantConfig: Codable, Equatable, Sendable {
    public var tenantID: String
    public var configVersion: Int
    public var allowedOrigins: [String]
    public var ui: BalakunUIConfig?
    public var metrics: BalakunMetricsConfig?
    public var tts: BalakunTTSConfig?
    public var history: BalakunHistoryConfig?

    public init(
        tenantID: String,
        configVersion: Int,
        allowedOrigins: [String],
        ui: BalakunUIConfig? = nil,
        metrics: BalakunMetricsConfig? = nil,
        tts: BalakunTTSConfig? = nil,
        history: BalakunHistoryConfig? = nil
    ) {
        self.tenantID = tenantID
        self.configVersion = configVersion
        self.allowedOrigins = allowedOrigins
        self.ui = ui
        self.metrics = metrics
        self.tts = tts
        self.history = history
    }

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenantId"
        case configVersion
        case allowedOrigins
        case ui
        case metrics
        case tts
        case history
    }
}

/// UI settings returned in tenant config.
public struct BalakunUIConfig: Codable, Equatable, Sendable {
    public var title: String?
    public var welcomeMessages: [String]?
    public var conversationRating: Bool?
    public var productLinkAllowlist: [String]?
}

/// Voice/TTS controls returned in tenant config.
public struct BalakunTTSConfig: Codable, Equatable, Sendable {
    public var audioTagProcessingEnabled: Bool?
    public var voiceInterfaceEnabled: Bool?
}

/// Local-history controls returned in tenant config.
public struct BalakunHistoryConfig: Codable, Equatable, Sendable {
    public var maxMessages: Int?
    public var localTtlMonths: Int?

    @available(*, deprecated, renamed: "localTtlMonths")
    public var localTTlMonths: Int? {
        get { localTtlMonths }
        set { localTtlMonths = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case maxMessages
        case localTtlMonths
    }
}

/// Metrics settings returned in tenant config.
public struct BalakunMetricsConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var sampleRate: Double?
    public var destinations: [BalakunMetricsDestination]?
}

/// Metrics destination descriptor.
public struct BalakunMetricsDestination: Codable, Equatable, Sendable {
    public var type: String
    public var enabled: Bool?
    public var measurementID: String?
    public var tenantDimension: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case enabled
        case measurementID
        case tenantDimension
    }
}
