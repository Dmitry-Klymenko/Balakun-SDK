import Foundation
import XCTest
@testable import BalakunMobileSDK

extension BalakunClientTests {
    func testBootstrapUsesPersistedSessionWithoutEmbedToken() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let persistedSession = BalakunSession(
            token: "persisted-session-token",
            conversationID: "conversation-persisted",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let sessionStore = InMemorySessionStore(initialSession: persistedSession, tenantID: tenantID)

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [URLProtocolStub.self]
        let urlSession = URLSession(configuration: urlSessionConfiguration)

        let requestCapture = RequestCapture()

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            requestCapture.recordPath(url.path)

            switch url.path {
            case "/t/\(tenantID)/config":
                requestCapture.recordConfigToken(
                    request.value(forHTTPHeaderField: "X-Waybeam-Session-Token")
                )
                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            default:
                XCTFail("Unexpected request path: \(url.path)")
                throw URLError(.badServerResponse)
            }
        }

        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                baseURL: URL(string: "https://balakun.waybeam.ai")!,
                tenantID: tenantID,
                parentOrigin: URL(string: "https://mobile.example.com")!,
                defaultParentURL: URL(string: "https://mobile.example.com/chat"),
                embedTokenProvider: nil,
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let config = try await client.bootstrap()
        XCTAssertEqual(config.tenantID, "demo")

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.paths, ["/t/\(tenantID)/config"])
        XCTAssertEqual(snapshot.configTokens, ["persisted-session-token"])
    }

    /// Verifies `bootstrap()` does not send an expired persisted session token to `/config`.
    func testBootstrapSkipsExpiredPersistedSessionForConfigRequest() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let expiredSession = BalakunSession(
            token: "expired-session-token",
            conversationID: "conversation-expired",
            expiresAt: Date().addingTimeInterval(-600)
        )
        let sessionStore = InMemorySessionStore(initialSession: expiredSession, tenantID: tenantID)

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [URLProtocolStub.self]
        let urlSession = URLSession(configuration: urlSessionConfiguration)

        let requestCapture = RequestCapture()

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            requestCapture.recordPath(url.path)

            switch url.path {
            case "/t/\(tenantID)/config":
                let sessionToken = request.value(forHTTPHeaderField: "X-Waybeam-Session-Token")
                requestCapture.recordConfigToken(sessionToken)
                if sessionToken != nil {
                    return makeResponse(
                        request: request,
                        statusCode: 401,
                        contentType: "application/json",
                        body: Data("expired_session_not_allowed".utf8)
                    )
                }

                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            default:
                XCTFail("Unexpected request path: \(url.path)")
                throw URLError(.badServerResponse)
            }
        }

        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                baseURL: URL(string: "https://balakun.waybeam.ai")!,
                tenantID: tenantID,
                parentOrigin: URL(string: "https://mobile.example.com")!,
                defaultParentURL: URL(string: "https://mobile.example.com/chat"),
                embedTokenProvider: { "embed-token" },
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let config = try await client.bootstrap()
        XCTAssertEqual(config.tenantID, "demo")

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.paths, ["/t/\(tenantID)/config"])
        XCTAssertEqual(snapshot.configTokens, [nil])
    }

    /// Verifies `bootstrap()` retries config without session token when persisted token is rejected.
    func testBootstrapRetriesConfigWithoutSessionWhenSessionRejected() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let persistedSession = BalakunSession(
            token: "persisted-session-token",
            conversationID: "conversation-persisted",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let sessionStore = InMemorySessionStore(initialSession: persistedSession, tenantID: tenantID)

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [URLProtocolStub.self]
        let urlSession = URLSession(configuration: urlSessionConfiguration)

        let requestCapture = RequestCapture()

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            requestCapture.recordPath(url.path)

            switch url.path {
            case "/t/\(tenantID)/config":
                let sessionToken = request.value(forHTTPHeaderField: "X-Waybeam-Session-Token")
                requestCapture.recordConfigToken(sessionToken)

                if sessionToken != nil {
                    return makeResponse(
                        request: request,
                        statusCode: 403,
                        contentType: "application/json",
                        body: Data("session_rejected".utf8)
                    )
                }

                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            default:
                XCTFail("Unexpected request path: \(url.path)")
                throw URLError(.badServerResponse)
            }
        }

        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                baseURL: URL(string: "https://balakun.waybeam.ai")!,
                tenantID: tenantID,
                parentOrigin: URL(string: "https://mobile.example.com")!,
                defaultParentURL: URL(string: "https://mobile.example.com/chat"),
                embedTokenProvider: { "embed-token" },
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let config = try await client.bootstrap()
        XCTAssertEqual(config.tenantID, "demo")

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.paths, ["/t/\(tenantID)/config", "/t/\(tenantID)/config"])
        XCTAssertEqual(snapshot.configTokens, ["persisted-session-token", nil])

        let stored = await sessionStore.loadSession(for: tenantID)
        XCTAssertNil(stored)
    }

    /// Verifies chat request derives parent page URL from origin, base path and runtime screen name.
}
