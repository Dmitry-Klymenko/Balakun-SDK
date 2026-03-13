import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BalakunClient {
    func tenantPath(_ route: String) -> String {
        "/t/\(configuration.tenantID)/\(route)"
    }

    func resolveChatURL() -> URL {
        switch configuration.transport {
        case .embedGateway:
            return configuration.baseURL.appendingPathComponent(tenantPath("chat"))
        case .direct(let url, _):
            return url
        }
    }

    func parentOriginString() -> String {
        guard let components = URLComponents(url: configuration.parentOrigin, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else {
            return configuration.parentOrigin.absoluteString
        }
        return components.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    func currentClientID() -> String {
        if let provided = configuration.clientIDProvider?().trimmedNonEmpty {
            return provided
        }
        if let generatedClientID {
            return generatedClientID
        }
        let random = Int.random(in: 1_000_000_000...9_999_999_999)
        let timestamp = String(Int(Date().timeIntervalSince1970), radix: 36)
        let generated = "v1.\(random).\(timestamp)"
        generatedClientID = generated
        return generated
    }

    func currentEmbedToken() async throws -> String? {
        guard let provider = configuration.embedTokenProvider else {
            return nil
        }
        return try await provider()
    }

    func applyEmbedTokenHeader(to request: inout URLRequest) async throws {
        guard let embedToken = try await currentEmbedToken()?.trimmedNonEmpty else {
            return
        }
        request.setValue(embedToken, forHTTPHeaderField: BalakunRequestHeader.embedToken)
    }

    func applyResolvedClientIDHeader(to request: inout URLRequest) {
        request.setValue(currentClientID(), forHTTPHeaderField: BalakunRequestHeader.clientID)
    }

    func emitAutoAnalytics(
        event: String,
        metrics: [String: BalakunAnalyticsValue] = [:],
        context: BalakunRuntimeContext
    ) {
        var merged = metrics
        merged[BalakunAnalyticsKey.origin] = .string(parentOriginString())

        if let path = pathFromPageURL(context.pageURL ?? configuration.defaultParentURL?.absoluteString) {
            merged[BalakunAnalyticsKey.path] = .string(path)
        }

        configuration.analyticsHandler?(BalakunAnalyticsSignal(event: event, metrics: merged))
    }

    func pathFromPageURL(_ stringValue: String?) -> String? {
        guard let stringValue,
              let url = URL(string: stringValue) else {
            return nil
        }
        return url.path.isEmpty ? "/" : url.path
    }

    func resolvePageURL(for context: BalakunRuntimeContext) -> String? {
        if let explicit = context.pageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           let normalizedExplicit = normalizeExplicitPageURL(explicit) {
            return normalizedExplicit
        }

        let basePath = normalizeBasePath(
            context.pagePath
            ?? configuration.defaultParentPath
            ?? configuration.defaultParentURL?.path
        )
        let screenSegment = normalizeScreenNameAsPathSegment(context.screenName)

        if let basePath, let screenSegment {
            return buildPageURL(basePath: basePath, screenSegment: screenSegment)
        }
        if let basePath {
            return buildPageURL(basePath: basePath, screenSegment: nil)
        }

        return configuration.defaultParentURL?.absoluteString
    }

    func normalizeExplicitPageURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let absoluteURL = URL(string: trimmed),
           let scheme = absoluteURL.scheme,
           let host = absoluteURL.host,
           !scheme.isEmpty,
           !host.isEmpty {
            guard var components = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: false) else {
                return absoluteURL.absoluteString
            }
            components.fragment = nil
            return components.url?.absoluteString ?? absoluteURL.absoluteString
        }

        guard let explicitComponents = URLComponents(string: trimmed) else {
            return nil
        }

        var path = explicitComponents.path
        if path.isEmpty {
            path = "/"
        } else if !path.hasPrefix("/") {
            path = "/" + path
        }
        path = path.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)

        guard var baseComponents = URLComponents(url: configuration.parentOrigin, resolvingAgainstBaseURL: false),
              baseComponents.scheme != nil,
              baseComponents.host != nil else {
            var fallback = "\(parentOriginString())\(path)"
            if let query = explicitComponents.query, !query.isEmpty {
                fallback += "?\(query)"
            }
            return fallback
        }

        baseComponents.path = path
        baseComponents.query = explicitComponents.query
        baseComponents.fragment = nil
        return baseComponents.url?.absoluteString
    }

    func buildPageURL(basePath: String, screenSegment: String?) -> String? {
        let fullPath: String
        if let screenSegment {
            fullPath = joinPath(basePath, screenSegment)
        } else {
            fullPath = basePath
        }

        guard var components = URLComponents(url: configuration.parentOrigin, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            return "\(parentOriginString())\(fullPath)"
        }

        components.path = fullPath
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "\(parentOriginString())\(fullPath)"
    }

    func normalizeBasePath(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        var path = raw
        if path.hasPrefix("http://") || path.hasPrefix("https://"),
           let url = URL(string: path) {
            path = url.path
        }

        if path.isEmpty {
            return nil
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        path = path.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
        if path.count > 1 {
            path = path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
        return path.isEmpty ? "/" : path
    }

    func normalizeScreenNameAsPathSegment(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let slug = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    func joinPath(_ basePath: String, _ segment: String) -> String {
        if basePath == "/" {
            return "/\(segment)"
        }
        return "\(basePath)/\(segment)"
    }

    func analyticsString(_ value: String?) -> BalakunAnalyticsValue {
        value.map(BalakunAnalyticsValue.string) ?? .null
    }

    func logEventSource(from event: BalakunLogEvent) -> String? {
        event.properties?["source"]?.stringValue
    }

    func encodeToJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    func applyConfigDefaults(_ config: BalakunPublicTenantConfig) -> BalakunPublicTenantConfig {
        var next = config
        if next.configVersion == 0 {
            next.configVersion = 1
        }
        if next.allowedOrigins.isEmpty {
            next.allowedOrigins = ["*"]
        }
        if next.metrics == nil {
            next.metrics = BalakunMetricsConfig(
                enabled: true,
                sampleRate: 1,
                destinations: [
                    BalakunMetricsDestination(
                        type: "balakunMetrics",
                        enabled: true,
                        measurementID: nil,
                        tenantDimension: nil
                    )
                ]
            )
        }
        if next.tts == nil {
            next.tts = BalakunTTSConfig(audioTagProcessingEnabled: false, voiceInterfaceEnabled: false)
        }
        return next
    }
}

enum BalakunRequestHeader {
    static let contentType = "Content-Type"
    static let accept = "Accept"
    static let origin = "Origin"
    static let parentOrigin = "X-Waybeam-Parent-Origin"
    static let parentURL = "X-Waybeam-Parent-Url"
    static let clientID = "X-Waybeam-Client-Id"
    static let sessionID = "X-Waybeam-Session-Id"
    static let sessionToken = "X-Waybeam-Session-Token"
    static let embedToken = "X-Waybeam-Embed-Token"
}

enum BalakunContentType {
    static let json = "application/json"
    static let eventStream = "text/event-stream"
}

extension BalakunJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int.min),
                  value <= Double(Int.max) else {
                return nil
            }
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    var arrayValue: [BalakunJSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
