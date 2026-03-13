import Foundation
import XCTest
@testable import BalakunMobileSDK

extension BalakunClientTests {
    func testBootstrapDoesNotRetryHTTP500() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)
        let requestCapture = RequestCapture()
        let urlSession = makeRetryURLSession()

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            requestCapture.recordPath(url.path)

            switch url.path {
            case "/t/\(tenantID)/config":
                return makeResponse(
                    request: request,
                    statusCode: 500,
                    contentType: "application/json",
                    body: Data("internal_error".utf8)
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

        do {
            _ = try await client.bootstrap()
            XCTFail("Expected bootstrap to fail")
        } catch let BalakunSDKError.httpError(status, _) {
            XCTAssertEqual(status, 500)
        }

        XCTAssertEqual(requestCapture.snapshot().paths, ["/t/\(tenantID)/config"])
    }

    func testBootstrapRetriesTransientConfigFailure() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)
        let requestCapture = RequestCapture()
        let urlSession = makeRetryURLSession()

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            requestCapture.recordPath(url.path)

            switch url.path {
            case "/t/\(tenantID)/config":
                let attempt = requestCapture.snapshot().paths.count
                if attempt == 1 {
                    return makeResponse(
                        request: request,
                        statusCode: 503,
                        contentType: "application/json",
                        body: Data("temporarily_unavailable".utf8)
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
                retryPolicy: .immediateForTests,
                sessionStore: sessionStore,
                urlSession: urlSession
            )
        )

        let config = try await client.bootstrap()
        XCTAssertEqual(config.tenantID, "demo")
        XCTAssertEqual(
            requestCapture.snapshot().paths,
            ["/t/\(tenantID)/config", "/t/\(tenantID)/config"]
        )
    }

    func testSendMessageRetriesSessionCreationTransportFailure() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)
        let requestCapture = RequestCapture()
        let urlSession = makeRetryURLSession()

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
                requestCapture.incrementSessionCreateCount()
                if requestCapture.snapshot().sessionCreateCount == 1 {
                    throw URLError(.timedOut)
                }

                let body = #"{"token":"fresh-token","conversationId":"conversation-1","expiresAt":4102444800000}"#
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
        for try await _ in stream {}

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.sessionCreateCount, 2)
        XCTAssertEqual(snapshot.chatTokens, ["fresh-token"])
    }

    func testSendMessageRetriesTransientChatTransportFailure() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)
        let requestCapture = RequestCapture()
        let urlSession = makeRetryURLSession()

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
                requestCapture.incrementSessionCreateCount()
                let body = #"{"token":"fresh-token","conversationId":"conversation-1","expiresAt":4102444800000}"#
                return makeResponse(
                    request: request,
                    statusCode: 200,
                    contentType: "application/json",
                    body: Data(body.utf8)
                )

            case "/t/\(tenantID)/chat":
                let attempt = requestCapture.recordChatToken(
                    request.value(forHTTPHeaderField: "X-Waybeam-Session-Token") ?? "<missing>"
                )

                if attempt == 1 {
                    throw URLError(.networkConnectionLost)
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
        XCTAssertEqual(snapshot.chatTokens, ["fresh-token", "fresh-token"])
        XCTAssertTrue(didReceiveDone)
    }

    private func makeRetryURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}
