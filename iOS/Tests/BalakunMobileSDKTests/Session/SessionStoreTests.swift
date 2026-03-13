import XCTest
@testable import BalakunMobileSDK

/// Unit tests for SDK session persistence store.
final class SessionStoreTests: XCTestCase {
    /// Verifies session round-trip save/load behavior.
    func testUserDefaultsSessionStoreRoundTrip() async {
        let keyPrefix = "balakun.sdk.tests.\(UUID().uuidString)"
        let store = BalakunUserDefaultsSessionStore(keyPrefix: keyPrefix)
        let session = BalakunSession(
            token: "session-token",
            conversationID: "conversation-1",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        await store.saveSession(session, for: "demo")
        let loaded = await store.loadSession(for: "demo")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.token, session.token)
        XCTAssertEqual(loaded?.conversationID, session.conversationID)
        if let loaded {
            XCTAssertEqual(loaded.expiresAt.timeIntervalSince1970, session.expiresAt.timeIntervalSince1970, accuracy: 0.001)
        }

        await store.clearSession(for: "demo")
    }

    /// Verifies that clearing a session removes persisted tenant state.
    func testUserDefaultsSessionStoreClear() async {
        let keyPrefix = "balakun.sdk.tests.\(UUID().uuidString)"
        let store = BalakunUserDefaultsSessionStore(keyPrefix: keyPrefix)
        let session = BalakunSession(
            token: "session-token",
            conversationID: "conversation-1",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        await store.saveSession(session, for: "demo")
        await store.clearSession(for: "demo")

        let loaded = await store.loadSession(for: "demo")
        XCTAssertNil(loaded)
    }
}
