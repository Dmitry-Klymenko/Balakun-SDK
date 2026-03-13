import Foundation
import XCTest
@testable import BalakunMobileSDK

/// In-memory session store used by client tests.
actor InMemorySessionStore: BalakunSessionStore {
    private var sessions: [String: BalakunSession] = [:]

    /// Creates an in-memory store with optional initial session value.
    ///
    /// - Parameters:
    ///   - initialSession: Optional session value for seed tenant.
    ///   - tenantID: Tenant identifier that receives the initial session.
    init(initialSession: BalakunSession?, tenantID: String) {
        if let initialSession {
            sessions[tenantID] = initialSession
        }
    }

    /// Loads session for a tenant.
    ///
    /// - Parameter tenantID: Tenant identifier.
    /// - Returns: Stored session when available.
    func loadSession(for tenantID: String) async -> BalakunSession? {
        sessions[tenantID]
    }

    /// Persists session for a tenant.
    ///
    /// - Parameters:
    ///   - session: Session to store.
    ///   - tenantID: Tenant identifier.
    func saveSession(_ session: BalakunSession, for tenantID: String) async {
        sessions[tenantID] = session
    }

    /// Removes session for a tenant.
    ///
    /// - Parameter tenantID: Tenant identifier.
    func clearSession(for tenantID: String) async {
        sessions[tenantID] = nil
    }
}

/// Thread-safe container for per-test request capture state.
final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var chatTokens: [String] = []
    private var feedbackTokens: [String] = []
    private var clientIDs: [String?] = []
    private var configTokens: [String?] = []
    private var chatParentURLs: [String?] = []
    private var chatAttemptCount = 0
    private var feedbackAttemptCount = 0
    private var refreshCount = 0
    private var sessionCreateCount = 0

    /// Records a request path for diagnostic assertions.
    ///
    /// - Parameter path: Request URL path.
    func recordPath(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    /// Records request client identifier value.
    ///
    /// - Parameter clientID: Client ID request header value.
    func recordClientID(_ clientID: String?) {
        lock.lock()
        clientIDs.append(clientID)
        lock.unlock()
    }

    /// Records config request session token header value.
    ///
    /// - Parameter token: Session token from config request.
    func recordConfigToken(_ token: String?) {
        lock.lock()
        configTokens.append(token)
        lock.unlock()
    }

    /// Records `X-Waybeam-Parent-Url` from chat request.
    ///
    /// - Parameter url: Parent page URL header value.
    func recordChatParentURL(_ url: String?) {
        lock.lock()
        chatParentURLs.append(url)
        lock.unlock()
    }

    /// Records a chat request token and returns the current attempt number.
    ///
    /// - Parameter token: Session token from request header.
    /// - Returns: 1-based chat attempt count.
    func recordChatToken(_ token: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        chatAttemptCount += 1
        chatTokens.append(token)
        return chatAttemptCount
    }

    /// Records a feedback request token and returns the current attempt number.
    ///
    /// - Parameter token: Session token from request header.
    /// - Returns: 1-based feedback attempt count.
    func recordFeedbackToken(_ token: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        feedbackAttemptCount += 1
        feedbackTokens.append(token)
        return feedbackAttemptCount
    }

    /// Increments refresh call counter.
    func incrementRefreshCount() {
        lock.lock()
        refreshCount += 1
        lock.unlock()
    }

    /// Increments session-create call counter.
    func incrementSessionCreateCount() {
        lock.lock()
        sessionCreateCount += 1
        lock.unlock()
    }

    /// Returns immutable snapshot of captured request state.
    ///
    /// - Returns: Captured request details.
    func snapshot() -> RequestCaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RequestCaptureSnapshot(
            paths: paths,
            chatTokens: chatTokens,
            feedbackTokens: feedbackTokens,
            clientIDs: clientIDs,
            configTokens: configTokens,
            chatParentURLs: chatParentURLs,
            refreshCount: refreshCount,
            sessionCreateCount: sessionCreateCount
        )
    }
}

struct RequestCaptureSnapshot {
    let paths: [String]
    let chatTokens: [String]
    let feedbackTokens: [String]
    let clientIDs: [String?]
    let configTokens: [String?]
    let chatParentURLs: [String?]
    let refreshCount: Int
    let sessionCreateCount: Int
}

extension BalakunRetryPolicy {
    static let immediateForTests = BalakunRetryPolicy(
        maxAttempts: 3,
        initialDelay: 0,
        multiplier: 2,
        maxDelay: 0
    )
}

/// URL protocol stub for intercepting SDK HTTP requests in tests.
class URLProtocolStub: URLProtocol {
    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: RequestHandler?

    /// Sets request handler closure used for intercepted requests.
    ///
    /// - Parameter handler: Request handler.
    static func setRequestHandler(_ handler: @escaping RequestHandler) {
        lock.lock()
        requestHandler = handler
        lock.unlock()
    }

    /// Clears any configured request handler.
    static func reset() {
        lock.lock()
        requestHandler = nil
        lock.unlock()
    }

    /// Indicates this protocol can handle all requests for test sessions.
    override class func canInit(with request: URLRequest) -> Bool {
        _ = request
        return true
    }

    /// Returns canonical form of request.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Starts handling intercepted request.
    override func startLoading() {
        URLProtocolStub.lock.lock()
        let handler = URLProtocolStub.requestHandler
        URLProtocolStub.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// Stops request loading. Not needed for this test stub.
    override func stopLoading() {}
}

/// Builds an HTTP response tuple for URL protocol handlers.
///
/// - Parameters:
///   - request: Intercepted request.
///   - statusCode: HTTP status code.
///   - contentType: Value for `Content-Type` header.
///   - body: Raw response body.
/// - Returns: Response/data tuple.
func makeResponse(
    request: URLRequest,
    statusCode: Int,
    contentType: String,
    body: Data
) -> (HTTPURLResponse, Data) {
    let headers = ["Content-Type": contentType]
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
    return (response, body)
}
