import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BalakunTransport: Sendable {
    case embedGateway
    case direct(url: URL, headers: [String: String] = [:])
}

public protocol BalakunSessionStore: Sendable {
    func loadSession(for tenantID: String) async -> BalakunSession?

    func saveSession(_ session: BalakunSession, for tenantID: String) async

    func clearSession(for tenantID: String) async
}

public actor BalakunUserDefaultsSessionStore: BalakunSessionStore {
    private let userDefaults: UserDefaults
    private let keyPrefix: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(userDefaults: UserDefaults = .standard, keyPrefix: String = "balakun.session") {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func loadSession(for tenantID: String) async -> BalakunSession? {
        let key = key(for: tenantID)
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }
        return try? decoder.decode(BalakunSession.self, from: data)
    }

    public func saveSession(_ session: BalakunSession, for tenantID: String) async {
        let key = key(for: tenantID)
        if let data = try? encoder.encode(session) {
            userDefaults.set(data, forKey: key)
        }
    }

    public func clearSession(for tenantID: String) async {
        userDefaults.removeObject(forKey: key(for: tenantID))
    }

    private func key(for tenantID: String) -> String {
        "\(keyPrefix).\(tenantID)"
    }
}

public struct BalakunSDKConfiguration {
    public var baseURL: URL
    public var tenantID: String
    public var parentOrigin: URL
    public var defaultParentURL: URL?
    public var defaultParentPath: String?
    public var transport: BalakunTransport
    public var embedTokenProvider: (@Sendable () async throws -> String)?
    public var clientIDProvider: (@Sendable () -> String)?
    public var analyticsHandler: (@Sendable (BalakunAnalyticsSignal) -> Void)?
    public var retryPolicy: BalakunRetryPolicy
    public var sessionStore: BalakunSessionStore?
    public var urlSession: URLSession

    public init(
        baseURL: URL = URL(string: "https://balakun.waybeam.ai")!,
        tenantID: String,
        parentOrigin: URL,
        defaultParentURL: URL? = nil,
        defaultParentPath: String? = nil,
        transport: BalakunTransport = .embedGateway,
        embedTokenProvider: (@Sendable () async throws -> String)? = nil,
        clientIDProvider: (@Sendable () -> String)? = nil,
        analyticsHandler: (@Sendable (BalakunAnalyticsSignal) -> Void)? = nil,
        retryPolicy: BalakunRetryPolicy = .default,
        sessionStore: BalakunSessionStore? = nil,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tenantID = tenantID
        self.parentOrigin = parentOrigin
        self.defaultParentURL = defaultParentURL
        self.defaultParentPath = defaultParentPath
        self.transport = transport
        self.embedTokenProvider = embedTokenProvider
        self.clientIDProvider = clientIDProvider
        self.analyticsHandler = analyticsHandler
        self.retryPolicy = retryPolicy
        self.sessionStore = sessionStore
        self.urlSession = urlSession
    }
}

/// Retry policy for transient SDK transport failures.
public struct BalakunRetryPolicy: Sendable {
    public static let `default` = BalakunRetryPolicy()

    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval

    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.25,
        multiplier: Double = 2.0,
        maxDelay: TimeInterval = 2.0
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
    }
}

public enum BalakunSDKError: Error, LocalizedError {
    case invalidConfiguration(String)
    case sessionUnavailable
    case invalidResponse
    case httpError(status: Int, body: String?)
    case invalidContentType(expected: String, actual: String)
    case missingResponseBody
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid Balakun SDK configuration: \(message)"
        case .sessionUnavailable:
            return "Session token is unavailable"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .httpError(let status, let body):
            return "HTTP \(status): \(body ?? "unknown_error")"
        case .invalidContentType(let expected, let actual):
            return "Invalid content type. Expected \(expected), got \(actual)"
        case .missingResponseBody:
            return "Missing response body"
        case .decodingError(let message):
            return "Decoding error: \(message)"
        }
    }
}

public struct BalakunSession: Codable, Equatable, Sendable {
    public let token: String
    public let conversationID: String
    public let expiresAt: Date

    public init(token: String, conversationID: String, expiresAt: Date) {
        self.token = token
        self.conversationID = conversationID
        self.expiresAt = expiresAt
    }
}
