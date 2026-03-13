import Foundation
import XCTest
@testable import BalakunMobileSDK

extension BalakunClientTests {
    func testSubmitFeedbackRetriesWithRefreshedSessionAndEmitsRatingAnalytics() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let requestCapture = RequestCapture()
        let analyticsCapture = AnalyticsCapture()

        URLProtocolStub.setRequestHandler { request in
            try feedbackRetryResponse(
                request: request,
                tenantID: tenantID,
                requestCapture: requestCapture,
                response: FeedbackRefreshResponse(
                    firstStatusCode: 401,
                    token: "new-token",
                    conversationID: "conversation-2"
                )
            )
        }

        let sessionStore = makeFeedbackSessionStore(tenantID: tenantID)
        let client = makeFeedbackClient(
            tenantID: tenantID,
            sessionStore: sessionStore,
            analyticsCapture: analyticsCapture,
            retryPolicy: .immediateForTests
        )

        try await client.submitFeedback(messageID: "message-1", rating: 1)

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.refreshCount, 1)
        XCTAssertEqual(snapshot.sessionCreateCount, 0)
        XCTAssertEqual(snapshot.feedbackTokens, ["old-token", "new-token"])

        let stored = await sessionStore.loadSession(for: tenantID)
        XCTAssertEqual(stored?.token, "new-token")
        XCTAssertEqual(stored?.conversationID, "conversation-2")

        let signals = analyticsCapture.signals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.event, BalakunAnalyticsEventName.chatMessageRated)
        XCTAssertEqual(signals.first?.metrics[BalakunAnalyticsKey.messageID], .string("message-1"))
        XCTAssertEqual(signals.first?.metrics[BalakunAnalyticsKey.rating], .number(1))
    }

    func testSubmitFeedbackRetriesWithNewSessionWhenRefreshFails() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let requestCapture = RequestCapture()
        let analyticsCapture = AnalyticsCapture()

        installRefreshFailureHandler(
            tenantID: tenantID,
            requestCapture: requestCapture,
            recreatedToken: "recreated-token",
            recreatedConversationID: "conversation-3"
        )

        let sessionStore = makeFeedbackSessionStore(tenantID: tenantID)
        let client = makeFeedbackClient(
            tenantID: tenantID,
            sessionStore: sessionStore,
            analyticsCapture: analyticsCapture
        )

        try await client.submitFeedback(
            messageID: "message-2",
            reasonCode: "irrelevant",
            reasonText: "not grounded"
        )

        let snapshot = requestCapture.snapshot()
        XCTAssertEqual(snapshot.refreshCount, 3)
        XCTAssertEqual(snapshot.sessionCreateCount, 1)
        XCTAssertEqual(snapshot.feedbackTokens, ["old-token", "recreated-token"])

        let stored = await sessionStore.loadSession(for: tenantID)
        XCTAssertEqual(stored?.token, "recreated-token")
        XCTAssertEqual(stored?.conversationID, "conversation-3")

        let signals = analyticsCapture.signals()
        XCTAssertEqual(signals.map(\.event), [BalakunAnalyticsEventName.chatSessionCreated])
    }
}

private extension BalakunClientTests {
    func makeFeedbackSessionStore(tenantID: String) -> InMemorySessionStore {
        let staleSession = BalakunSession(
            token: "old-token",
            conversationID: "conversation-1",
            expiresAt: Date().addingTimeInterval(3600)
        )
        return InMemorySessionStore(initialSession: staleSession, tenantID: tenantID)
    }

    func makeFeedbackClient(
        tenantID: String,
        sessionStore: InMemorySessionStore,
        analyticsCapture: AnalyticsCapture,
        retryPolicy: BalakunRetryPolicy = .default
    ) -> BalakunClient {
        BalakunClient(
            configuration: BalakunSDKConfiguration(
                baseURL: URL(string: "https://balakun.waybeam.ai")!,
                tenantID: tenantID,
                parentOrigin: URL(string: "https://mobile.example.com")!,
                defaultParentURL: URL(string: "https://mobile.example.com/chat"),
                embedTokenProvider: { "embed-token" },
                analyticsHandler: { signal in analyticsCapture.record(signal) },
                retryPolicy: retryPolicy,
                sessionStore: sessionStore,
                urlSession: makeFeedbackURLSession()
            )
        )
    }

    func makeFeedbackURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    func installRefreshFailureHandler(
        tenantID: String,
        requestCapture: RequestCapture,
        recreatedToken: String,
        recreatedConversationID: String
    ) {
        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            requestCapture.recordPath(url.path)

            switch url.path {
            case "/t/\(tenantID)/feedback":
                let attempt = requestCapture.recordFeedbackToken(
                    request.value(forHTTPHeaderField: "X-Waybeam-Session-Token") ?? "<missing>"
                )
                if attempt == 1 {
                    return makeResponse(
                        request: request,
                        statusCode: 403,
                        contentType: "application/json",
                        body: Data("forbidden".utf8)
                    )
                }

                return makeResponse(
                    request: request,
                    statusCode: 204,
                    contentType: "application/json",
                    body: Data()
                )

            case "/t/\(tenantID)/session/refresh":
                requestCapture.incrementRefreshCount()
                throw URLError(.timedOut)

            case "/t/\(tenantID)/session":
                requestCapture.incrementSessionCreateCount()
                let body = """
                    {"token":"\(recreatedToken)",
                    "conversationId":"\(recreatedConversationID)",
                    "expiresAt":4102444800000}
                    """
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
    }
}

private struct FeedbackRefreshResponse {
    let firstStatusCode: Int
    let token: String
    let conversationID: String
}

private func feedbackRetryResponse(
    request: URLRequest,
    tenantID: String,
    requestCapture: RequestCapture,
    response: FeedbackRefreshResponse
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url else {
        throw URLError(.badURL)
    }
    requestCapture.recordPath(url.path)

    switch url.path {
    case "/t/\(tenantID)/feedback":
        let attempt = requestCapture.recordFeedbackToken(
            request.value(forHTTPHeaderField: "X-Waybeam-Session-Token") ?? "<missing>"
        )
        if attempt == 1 {
            return makeResponse(
                request: request,
                statusCode: response.firstStatusCode,
                contentType: "application/json",
                body: Data((response.firstStatusCode == 401 ? "unauthorized" : "forbidden").utf8)
            )
        }
        return makeResponse(
            request: request,
            statusCode: 204,
            contentType: "application/json",
            body: Data()
        )

    case "/t/\(tenantID)/session/refresh":
        requestCapture.incrementRefreshCount()
        let body = """
            {"token":"\(response.token)","conversationId":"\(response.conversationID)","expiresAt":4102444800000}
            """
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

private final class AnalyticsCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BalakunAnalyticsSignal] = []

    func record(_ signal: BalakunAnalyticsSignal) {
        lock.lock()
        values.append(signal)
        lock.unlock()
    }

    func signals() -> [BalakunAnalyticsSignal] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
