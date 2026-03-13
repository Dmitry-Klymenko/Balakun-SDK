import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BalakunClient {
    func submitFeedbackRequest(
        messageID: String,
        rating: Int?,
        reasonCode: String?,
        reasonText: String?
    ) async throws {
        var activeSession = try await ensureSessionToken()
        let payload = FeedbackRequest(
            messageId: messageID,
            rating: rating,
            reasonCode: reasonCode,
            reasonText: reasonText
        )

        for attempt in 0..<2 {
            let request = try await buildFeedbackRequest(session: activeSession, payload: payload)
            let (data, http) = try await performDataRequest(request)

            if (200...299).contains(http.statusCode) {
                return
            }

            let isUnauthorized = http.statusCode == 401 || http.statusCode == 403
            if isUnauthorized, attempt == 0 {
                activeSession = try await recoverSessionAfterUnauthorized(context: BalakunRuntimeContext())
                continue
            }

            throw BalakunSDKError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
    }

    private func buildFeedbackRequest(session: BalakunSession, payload: FeedbackRequest) async throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(tenantPath("feedback")))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(payload)
        request.setValue(BalakunContentType.json, forHTTPHeaderField: BalakunRequestHeader.contentType)
        request.setValue(session.token, forHTTPHeaderField: BalakunRequestHeader.sessionToken)
        request.setValue(session.conversationID, forHTTPHeaderField: BalakunRequestHeader.sessionID)
        request.setValue(parentOriginString(), forHTTPHeaderField: BalakunRequestHeader.parentOrigin)
        applyResolvedClientIDHeader(to: &request)

        if let parentURL = configuration.defaultParentURL?.absoluteString {
            request.setValue(parentURL, forHTTPHeaderField: BalakunRequestHeader.parentURL)
        }

        try await applyEmbedTokenHeader(to: &request)
        return request
    }

    func fetchTenantConfig() async throws -> BalakunPublicTenantConfig {
        let activeSessionToken = sessionTokenForConfigRequest()
        let firstResponse = try await performConfigRequest(sessionToken: activeSessionToken)

        if firstResponse.isSuccess {
            return try decodeTenantConfig(from: firstResponse.data)
        }

        // If a cached session token is rejected, clear it and retry once without session auth.
        if activeSessionToken != nil,
           firstResponse.isUnauthorized {
            await setSession(nil)
            let retryResponse = try await performConfigRequest(sessionToken: nil)
            if retryResponse.isSuccess {
                return try decodeTenantConfig(from: retryResponse.data)
            }
            throw BalakunSDKError.httpError(
                status: retryResponse.http.statusCode,
                body: String(data: retryResponse.data, encoding: .utf8)
            )
        }

        throw BalakunSDKError.httpError(
            status: firstResponse.http.statusCode,
            body: String(data: firstResponse.data, encoding: .utf8)
        )
    }

    private func performConfigRequest(sessionToken: String?) async throws -> ConfigResponse {
        let request = try await buildConfigRequest(sessionToken: sessionToken)
        let (data, http) = try await performDataRequest(request)
        return ConfigResponse(data: data, http: http)
    }

    private func buildConfigRequest(sessionToken: String?) async throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(tenantPath("config")))
        request.httpMethod = "GET"
        request.setValue(parentOriginString(), forHTTPHeaderField: BalakunRequestHeader.parentOrigin)

        if let parentURL = configuration.defaultParentURL?.absoluteString {
            request.setValue(parentURL, forHTTPHeaderField: BalakunRequestHeader.parentURL)
        }

        applyResolvedClientIDHeader(to: &request)
        try await applyEmbedTokenHeader(to: &request)

        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: BalakunRequestHeader.sessionToken)
        }

        return request
    }

    private func sessionTokenForConfigRequest() -> String? {
        guard let session,
              session.expiresAt > Date() else {
            return nil
        }
        return session.token
    }

    private func decodeTenantConfig(from data: Data) throws -> BalakunPublicTenantConfig {
        do {
            return try decoder.decode(BalakunPublicTenantConfig.self, from: data)
        } catch {
            throw BalakunSDKError.decodingError(error.localizedDescription)
        }
    }

    func buildChatPayload(
        query: String,
        messageID: String,
        session: BalakunSession,
        context: BalakunRuntimeContext
    ) throws -> Data {
        let requestContext = ChatContextPayload(runtimeContext: context)
        let encodedContext = try encodeToJSONObject(requestContext) as? [String: Any]

        var payload: [String: Any] = [
            "query": query,
            "messageId": messageID,
            "conversationId": session.conversationID,
            "sessionId": session.conversationID
        ]

        if let encodedContext {
            payload["context"] = encodedContext
            payload["ui_context"] = encodedContext
        }

        if let recommendations = context.lastRecommendations {
            payload["last_recommendations"] = try encodeToJSONObject(recommendations)
        }

        if let retailState = context.retailState {
            payload["retail_state"] = try encodeToJSONObject(retailState)
        }

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    func buildChatRequest(
        streamURL: URL,
        payload: Data,
        session: BalakunSession,
        clientID: String,
        pageURL: String?
    ) async throws -> URLRequest {
        var request = URLRequest(url: streamURL)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue(BalakunContentType.json, forHTTPHeaderField: BalakunRequestHeader.contentType)
        request.setValue(BalakunContentType.eventStream, forHTTPHeaderField: BalakunRequestHeader.accept)
        request.setValue(parentOriginString(), forHTTPHeaderField: BalakunRequestHeader.parentOrigin)
        request.setValue(clientID, forHTTPHeaderField: BalakunRequestHeader.clientID)
        request.setValue(session.conversationID, forHTTPHeaderField: BalakunRequestHeader.sessionID)
        request.setValue(session.token, forHTTPHeaderField: BalakunRequestHeader.sessionToken)

        if let pageURL {
            request.setValue(pageURL, forHTTPHeaderField: BalakunRequestHeader.parentURL)
        }

        try await applyEmbedTokenHeader(to: &request)

        if case .direct(_, let extraHeaders) = configuration.transport {
            for (header, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }

        return request
    }

    func collectBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct ConfigResponse {
    let data: Data
    let http: HTTPURLResponse

    var isSuccess: Bool {
        (200...299).contains(http.statusCode)
    }

    var isUnauthorized: Bool {
        http.statusCode == 401 || http.statusCode == 403
    }
}

private struct FeedbackRequest: Codable {
    let messageId: String
    let rating: Int?
    let reasonCode: String?
    let reasonText: String?
}

private struct ChatContextPayload: Codable {
    let sessionID: String
    let requestID: String
    let pageURL: String?
    let pageTitle: String?
    let referrer: String?
    let locale: String?
    let device: String?
    let selectedText: String?
    let activeSection: String?
    let domAnchor: String?
    let visibleCTAs: [BalakunVisibleCTA]?
    let utm: BalakunUTM?
    let consentState: String?
    let uiCapabilities: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case requestID = "request_id"
        case pageURL = "page_url"
        case pageTitle = "page_title"
        case referrer
        case locale
        case device
        case selectedText = "selected_text"
        case activeSection = "active_section"
        case domAnchor = "dom_anchor"
        case visibleCTAs = "visible_ctas"
        case utm
        case consentState = "consent_state"
        case uiCapabilities = "ui_capabilities"
    }

    init(runtimeContext: BalakunRuntimeContext) {
        sessionID = UUID().uuidString
        requestID = UUID().uuidString
        pageURL = runtimeContext.pageURL
        pageTitle = runtimeContext.pageTitle
        self.referrer = runtimeContext.referrer
        self.locale = runtimeContext.locale
        self.device = runtimeContext.device
        selectedText = runtimeContext.selectedText
        activeSection = runtimeContext.activeSection
        domAnchor = runtimeContext.domAnchor
        visibleCTAs = runtimeContext.visibleCTAs
        self.utm = runtimeContext.utm
        consentState = runtimeContext.consentState
        uiCapabilities = runtimeContext.uiCapabilities
    }
}
