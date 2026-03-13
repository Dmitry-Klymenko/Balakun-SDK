import Foundation
import XCTest
@testable import BalakunMobileSDK

extension BalakunClientTests {
    func testSendMessageDerivesParentPageURLFromScreenName() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)

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
                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/session":
                let body = #"{"token":"fresh-token","conversationId":"conversation-1","expiresAt":4102444800000}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/chat":
                requestCapture.recordChatParentURL(
                    request.value(forHTTPHeaderField: "X-Waybeam-Parent-Url")
                )

                let streamBody = """
                data: [DONE]

                """
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: Data(streamBody.utf8)
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
                defaultParentPath: "/app",
                embedTokenProvider: { "embed-token" },
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let stream = await client.sendMessage(
            "hello",
            context: BalakunRuntimeContext(
                screenName: "Product Details"
            )
        )
        for try await _ in stream {}

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.paths, ["/t/\(tenantID)/config", "/t/\(tenantID)/session", "/t/\(tenantID)/chat"])
        XCTAssertEqual(snapshot.chatParentURLs, ["https://mobile.example.com/app/product-details"])
        let resolved = await client.resolvePageURL(for: BalakunRuntimeContext(screenName: "Product Details"))
        XCTAssertEqual(resolved, "https://mobile.example.com/app/product-details")
    }

    /// Verifies that a 401 chat response triggers session refresh and retries with the new token.
    func testSendMessageRetriesWithRefreshedSessionToken() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let staleSession = BalakunSession(
            token: "old-token",
            conversationID: "conversation-1",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let sessionStore = InMemorySessionStore(initialSession: staleSession, tenantID: tenantID)

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
                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/chat":
                let chatAttempt = requestCapture.recordChatToken(
                    request.value(forHTTPHeaderField: "X-Waybeam-Session-Token") ?? "<missing>"
                )

                if chatAttempt == 1 {
                    return makeResponse(
                        request: request,
                        statusCode: 401,
                        contentType: "application/json",
                        body: Data("unauthorized".utf8)
                    )
                }

                let streamBody = """
                data: [DONE]

                """
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: Data(streamBody.utf8)
                )

            case "/t/\(tenantID)/session/refresh":
                requestCapture.incrementRefreshCount()
                let body = #"{"token":"new-token","conversationId":"conversation-2","expiresAt":4102444800000}"#
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
                retryPolicy: .immediateForTests,
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let stream = await client.sendMessage("hello")
        var didReceiveDone = false

        do {
            for try await event in stream {
                switch event {
                case .done:
                    didReceiveDone = true
                default:
                    break
                }
            }
        } catch {
            let snapshot = requestCapture.snapshot()
            XCTFail("Stream failed: \(error). Paths=\(snapshot.paths) Tokens=\(snapshot.chatTokens)")
            return
        }

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.refreshCount, 1)
        XCTAssertEqual(snapshot.chatTokens, ["old-token", "new-token"])
        XCTAssertTrue(didReceiveDone)

        let stored = await sessionStore.loadSession(for: tenantID)
        XCTAssertEqual(stored?.token, "new-token")
        XCTAssertEqual(stored?.conversationID, "conversation-2")
    }

    /// Verifies chat retries by creating a new session when refresh fails.
    func testSendMessageRetriesWithNewSessionWhenRefreshFails() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let staleSession = BalakunSession(
            token: "old-token",
            conversationID: "conversation-1",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let sessionStore = InMemorySessionStore(initialSession: staleSession, tenantID: tenantID)

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
                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/chat":
                let chatAttempt = requestCapture.recordChatToken(
                    request.value(forHTTPHeaderField: "X-Waybeam-Session-Token") ?? "<missing>"
                )

                if chatAttempt == 1 {
                    return makeResponse(
                        request: request,
                        statusCode: 401,
                        contentType: "application/json",
                        body: Data("unauthorized".utf8)
                    )
                }

                let streamBody = """
                data: [DONE]

                """
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: Data(streamBody.utf8)
                )

            case "/t/\(tenantID)/session/refresh":
                requestCapture.incrementRefreshCount()
                return makeResponse(
                    request: request,
                    statusCode: 401,
                    contentType: "application/json",
                    body: Data("refresh_failed".utf8)
                )

            case "/t/\(tenantID)/session":
                requestCapture.incrementSessionCreateCount()
                let body = #"{"token":"recreated-token","conversationId":"conversation-3","expiresAt":4102444800000}"#
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

        let stream = await client.sendMessage("hello")
        var didReceiveDone = false

        do {
            for try await event in stream {
                if case .done = event {
                    didReceiveDone = true
                }
            }
        } catch {
            let snapshot = requestCapture.snapshot()
            XCTFail("Stream failed: \(error). Paths=\(snapshot.paths) Tokens=\(snapshot.chatTokens)")
            return
        }

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.refreshCount, 1)
        XCTAssertEqual(snapshot.sessionCreateCount, 1)
        XCTAssertEqual(snapshot.chatTokens, ["old-token", "recreated-token"])
        XCTAssertTrue(didReceiveDone)

        let stored = await sessionStore.loadSession(for: tenantID)
        XCTAssertEqual(stored?.token, "recreated-token")
        XCTAssertEqual(stored?.conversationID, "conversation-3")
    }

    /// Verifies unauthorized chat retry falls back to new session when refresh transport throws.
    func testSendMessageRetriesWithNewSessionWhenUnauthorizedRefreshThrows() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let staleSession = BalakunSession(
            token: "old-token",
            conversationID: "conversation-1",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let sessionStore = InMemorySessionStore(initialSession: staleSession, tenantID: tenantID)

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
                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/chat":
                let chatAttempt = requestCapture.recordChatToken(
                    request.value(forHTTPHeaderField: "X-Waybeam-Session-Token") ?? "<missing>"
                )

                if chatAttempt == 1 {
                    return makeResponse(
                        request: request,
                        statusCode: 401,
                        contentType: "application/json",
                        body: Data("unauthorized".utf8)
                    )
                }

                let streamBody = """
                data: [DONE]

                """
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: Data(streamBody.utf8)
                )

            case "/t/\(tenantID)/session/refresh":
                requestCapture.incrementRefreshCount()
                throw URLError(.timedOut)

            case "/t/\(tenantID)/session":
                requestCapture.incrementSessionCreateCount()
                let body = #"{"token":"recreated-token","conversationId":"conversation-4","expiresAt":4102444800000}"#
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
                retryPolicy: .immediateForTests,
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let stream = await client.sendMessage("hello")
        var didReceiveDone = false
        for try await event in stream {
            if case .done = event {
                didReceiveDone = true
            }
        }

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.refreshCount, 3)
        XCTAssertEqual(snapshot.sessionCreateCount, 1)
        XCTAssertEqual(snapshot.chatTokens, ["old-token", "recreated-token"])
        XCTAssertTrue(didReceiveDone)

        let stored = await sessionStore.loadSession(for: tenantID)
        XCTAssertEqual(stored?.token, "recreated-token")
        XCTAssertEqual(stored?.conversationID, "conversation-4")
    }

    /// Verifies chat stream creates a fresh session when refresh request throws transport error.
    func testSendMessageCreatesSessionWhenRefreshThrowsTransportError() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let expiredSession = BalakunSession(
            token: "expired-token",
            conversationID: "conversation-expired",
            expiresAt: Date().addingTimeInterval(-10)
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
                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/session/refresh":
                requestCapture.incrementRefreshCount()
                throw URLError(.timedOut)

            case "/t/\(tenantID)/session":
                requestCapture.incrementSessionCreateCount()
                let body = #"{"token":"fresh-token","conversationId":"conversation-fresh","expiresAt":4102444800000}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/chat":
                _ = requestCapture.recordChatToken(
                    request.value(forHTTPHeaderField: "X-Waybeam-Session-Token") ?? "<missing>"
                )
                let streamBody = """
                data: [DONE]

                """
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: Data(streamBody.utf8)
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
                retryPolicy: .immediateForTests,
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let stream = await client.sendMessage("hello")
        var didReceiveDone = false
        for try await event in stream {
            if case .done = event {
                didReceiveDone = true
            }
        }

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.refreshCount, 3)
        XCTAssertEqual(snapshot.sessionCreateCount, 1)
        XCTAssertEqual(snapshot.chatTokens, ["fresh-token"])
        XCTAssertTrue(didReceiveDone)
    }

    /// Verifies generated fallback client ID remains stable across config/session/chat requests.
    func testSendMessageUsesStableGeneratedClientID() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [URLProtocolStub.self]
        let urlSession = URLSession(configuration: urlSessionConfiguration)

        let requestCapture = RequestCapture()

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            requestCapture.recordPath(url.path)
            requestCapture.recordClientID(request.value(forHTTPHeaderField: "X-Waybeam-Client-Id"))

            switch url.path {
            case "/t/\(tenantID)/config":
                let body = #"{"tenantId":"demo","configVersion":1,"allowedOrigins":["*"]}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/session":
                let body = #"{"token":"fresh-token","conversationId":"conversation-1","expiresAt":4102444800000}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/chat":
                let streamBody = """
                data: [DONE]

                """
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: Data(streamBody.utf8)
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

        let stream = await client.sendMessage("hello")
        for try await _ in stream {}

        let snapshot = requestCapture.snapshot()
        let nonEmptyIDs = snapshot.clientIDs.compactMap { $0 }.filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(nonEmptyIDs.count, 3)
        XCTAssertEqual(Set(nonEmptyIDs).count, 1)
    }
}
