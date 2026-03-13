import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BalakunClient {
    func ensureSessionToken() async throws -> BalakunSession {
        await loadPersistedSessionIfNeeded()

        if let currentSession = session, currentSession.expiresAt > Date() {
            return currentSession
        }

        if let currentSession = session,
           currentSession.expiresAt <= Date() {
            do {
                if try await refreshSessionToken(),
                   let refreshed = self.session {
                    return refreshed
                }
            } catch {
                // Fallback to fresh session creation when refresh transport fails.
            }
        }

        let created = try await createSessionToken()
        await setSession(created)

        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatSessionCreated,
            metrics: [BalakunAnalyticsKey.sessionID: .string(created.conversationID)],
            context: .init()
        )

        return created
    }

    func createSessionToken() async throws -> BalakunSession {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(tenantPath("session")))
        request.httpMethod = "POST"
        request.setValue(parentOriginString(), forHTTPHeaderField: BalakunRequestHeader.origin)

        try await applyEmbedTokenHeader(to: &request)
        applyResolvedClientIDHeader(to: &request)

        let (data, http) = try await performDataRequest(request)

        guard (200...299).contains(http.statusCode) else {
            throw BalakunSDKError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }

        return try decodeSession(from: data)
    }

    @discardableResult
    func refreshSessionToken() async throws -> Bool {
        guard let existing = session else {
            return false
        }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(tenantPath("session/refresh")))
        request.httpMethod = "POST"
        request.setValue(existing.token, forHTTPHeaderField: BalakunRequestHeader.sessionToken)
        request.setValue(parentOriginString(), forHTTPHeaderField: BalakunRequestHeader.origin)

        try await applyEmbedTokenHeader(to: &request)
        applyResolvedClientIDHeader(to: &request)

        let (data, http) = try await performDataRequest(request)

        guard (200...299).contains(http.statusCode) else {
            return false
        }

        let refreshed = try decodeSession(from: data)
        await setSession(refreshed)
        return true
    }

    func decodeSession(from data: Data) throws -> BalakunSession {
        do {
            let payload = try decoder.decode(SessionResponse.self, from: data)
            return BalakunSession(
                token: payload.token,
                conversationID: payload.conversationId,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(payload.expiresAt) / 1000)
            )
        } catch {
            throw BalakunSDKError.decodingError(error.localizedDescription)
        }
    }

    func loadPersistedSessionIfNeeded() async {
        guard !hasLoadedSessionFromStore else {
            return
        }
        hasLoadedSessionFromStore = true
        if let stored = await configuration.sessionStore?.loadSession(for: configuration.tenantID) {
            session = stored
        }
    }

    func setSession(_ session: BalakunSession?) async {
        self.session = session
        if let session {
            await persistSession(session)
        } else {
            await clearPersistedSession()
        }
    }

    func persistSession(_ session: BalakunSession) async {
        await configuration.sessionStore?.saveSession(session, for: configuration.tenantID)
    }

    func clearPersistedSession() async {
        await configuration.sessionStore?.clearSession(for: configuration.tenantID)
    }
}

private struct SessionResponse: Codable {
    let token: String
    let conversationId: String
    let expiresAt: Int64
}
