import Foundation
import XCTest
@testable import BalakunMobileSDK

extension BalakunClientTests {
    func testSendMessageParsesCREndedSSEFramesWithoutMergingEvents() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [URLProtocolStub.self]
        let urlSession = URLSession(configuration: urlSessionConfiguration)

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

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
                let streamBody =
                    "event: model\r" +
                    "data: {\"model\":\"cf/model\",\"query_language_tag\":\"und\",\"language_confidence\":0.2}\r\r" +
                    "event: answer_delta\r" +
                    "data: {\"conversationId\":\"c1\",\"messageId\":\"m1\",\"seq\":1,\"ts\":1,\"t\":0,\"content\":\"Hello\"}\r\r" +
                    "event: done\r" +
                    "data: {}\r\r"
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
        var response = ""
        var didReceiveDone = false
        var unknownEventNames: [String] = []

        for try await event in stream {
            switch event {
            case .answerDelta(let payload):
                response += payload.content
            case .done:
                didReceiveDone = true
            case .unknown(let payload):
                unknownEventNames.append(payload.name)
            default:
                break
            }
        }

        XCTAssertEqual(response, "Hello")
        XCTAssertTrue(didReceiveDone)
        XCTAssertEqual(unknownEventNames, [])
    }

    /// Verifies duplicate terminal frames are collapsed to a single `.done` event.
    func testSendMessageYieldsDoneAtMostOnce() async throws {
        URLProtocolStub.reset()

        let tenantID = "demo"
        let sessionStore = InMemorySessionStore(initialSession: nil, tenantID: tenantID)

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [URLProtocolStub.self]
        let urlSession = URLSession(configuration: urlSessionConfiguration)

        URLProtocolStub.setRequestHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

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
                let streamBody =
                    "event: done\n" +
                    "data: {\"conversationId\":\"c1\",\"messageId\":\"m1\",\"seq\":1,\"ts\":1,\"t\":0,\"content\":\"Hello\"}\n" +
                    "data: {\"conversationId\":\"c1\",\"messageId\":\"m1\",\"seq\":2,\"ts\":2,\"t\":0}\n\n" +
                    "event: done\n" +
                    "data: {}\n\n"
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
        var response = ""
        var doneCount = 0

        for try await event in stream {
            switch event {
            case .answerDelta(let payload):
                response += payload.content
            case .done:
                doneCount += 1
            default:
                break
            }
        }

        XCTAssertEqual(response, "Hello")
        XCTAssertEqual(doneCount, 1)
    }

    /// Verifies stale completion callbacks cannot clear a newer active stream task.
    func testActiveStreamTaskClearIgnoresStaleTaskIdentifier() async {
        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                tenantID: "demo",
                parentOrigin: URL(string: "https://mobile.example.com")!
            )
        )

        let staleID = UUID()
        let activeID = UUID()
        let staleTask = Task<Void, Never> {}
        let activeTask = Task<Void, Never> {}
        defer {
            staleTask.cancel()
            activeTask.cancel()
        }

        await client.replaceActiveStreamTask(staleTask, id: staleID, order: 1)
        await client.replaceActiveStreamTask(activeTask, id: activeID, order: 2)

        await client.clearActiveStreamTask(id: staleID)
        let retainedIDAfterStaleClear = await client.activeStreamTaskID
        XCTAssertEqual(retainedIDAfterStaleClear, activeID)

        await client.clearActiveStreamTask(id: activeID)
        let retainedIDAfterActiveClear = await client.activeStreamTaskID
        XCTAssertNil(retainedIDAfterActiveClear)
    }

    /// Verifies out-of-order registration cannot override the newer active stream.
    func testReplaceActiveStreamTaskIgnoresStaleRegistrationOrder() async {
        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                tenantID: "demo",
                parentOrigin: URL(string: "https://mobile.example.com")!
            )
        )

        let newerID = UUID()
        let staleID = UUID()
        let newerTask = Task<Void, Never> {}
        let staleTask = Task<Void, Never> {}
        defer {
            newerTask.cancel()
            staleTask.cancel()
        }

        await client.replaceActiveStreamTask(newerTask, id: newerID, order: 2)
        await client.replaceActiveStreamTask(staleTask, id: staleID, order: 1)

        let retainedID = await client.activeStreamTaskID
        XCTAssertEqual(retainedID, newerID)
        XCTAssertTrue(staleTask.isCancelled)
    }

}
