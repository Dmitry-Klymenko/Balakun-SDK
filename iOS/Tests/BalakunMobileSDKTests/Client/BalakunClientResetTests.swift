import Foundation
import XCTest
@testable import BalakunMobileSDK

/// Unit tests for `BalakunClient` reset behavior.
final class BalakunClientResetTests: XCTestCase {
    /// Verifies session reset clears persisted session and retained per-conversation state.
    func testResetSessionClearsConversationDerivedState() async {
        let tenantID = "demo"
        let sessionStore = InMemoryResetSessionStore(initialSession: nil, tenantID: tenantID)

        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                tenantID: tenantID,
                parentOrigin: URL(string: "https://mobile.example.com")!,
                sessionStore: sessionStore
            )
        )

        let session = BalakunSession(
            token: "token-1",
            conversationID: "conversation-1",
            expiresAt: Date().addingTimeInterval(3600)
        )
        await client.setSession(session)
        await client.applyModelEvent(
            BalakunModelEvent(
                model: "cf/model",
                queryLanguageTag: "en",
                languageConfidence: 0.99
            )
        )
        await client.applyProductsEvent(
            BalakunProductsEvent(
                action: "products",
                mode: "replace",
                layout: "cards",
                referenceSetID: "set-1",
                title: nil,
                subtitle: nil,
                items: [
                    BalakunProductItem(
                        position: 1,
                        id: "id-1",
                        name: "Item 1",
                        url: "https://example.com/1",
                        images: nil
                    )
                ],
                memory: BalakunRecommendationMemory(
                    referenceSetID: "set-1",
                    items: [BalakunRecommendationItem(position: 1, name: "Item 1", url: "https://example.com/1")]
                )
            )
        )
        await client.applyClientStateCommands(
            [
                BalakunClientStateCommand(
                    op: "set",
                    key: "selected_position",
                    scope: nil,
                    value: .number(3),
                    reason: nil
                )
            ]
        )

        let sessionBeforeReset = await client.currentSession()
        let modelBeforeReset = await client.activeModelName
        let languageBeforeReset = await client.activeLanguageTag
        let recommendationsBeforeReset = await client.retainedRecommendations
        let retailStateBeforeReset = await client.retainedRetailState
        XCTAssertNotNil(sessionBeforeReset)
        XCTAssertEqual(modelBeforeReset, "cf/model")
        XCTAssertEqual(languageBeforeReset, "en")
        XCTAssertNotNil(recommendationsBeforeReset)
        XCTAssertEqual(retailStateBeforeReset?.selectedPosition, 3)

        await client.resetSession()

        let sessionAfterReset = await client.currentSession()
        let modelAfterReset = await client.activeModelName
        let languageAfterReset = await client.activeLanguageTag
        let recommendationsAfterReset = await client.retainedRecommendations
        let retailStateAfterReset = await client.retainedRetailState
        XCTAssertNil(sessionAfterReset)
        XCTAssertNil(modelAfterReset)
        XCTAssertNil(languageAfterReset)
        XCTAssertNil(recommendationsAfterReset)
        XCTAssertNil(retailStateAfterReset)
        let storedSessionAfterReset = await sessionStore.loadSession(for: tenantID)
        XCTAssertNil(storedSessionAfterReset)
    }

    /// Verifies products payloads without explicit `memory` still refresh retained recommendations.
    func testApplyProductsEventDerivesRecommendationMemoryWhenMemoryMissing() async {
        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                tenantID: "demo",
                parentOrigin: URL(string: "https://mobile.example.com")!
            )
        )

        await client.applyProductsEvent(
            BalakunProductsEvent(
                action: "products",
                mode: "replace",
                layout: "cards",
                referenceSetID: "set-new",
                title: nil,
                subtitle: nil,
                items: [
                    BalakunProductItem(
                        position: 1,
                        id: "id-new",
                        name: "New Item",
                        url: "https://example.com/new",
                        images: nil
                    )
                ],
                memory: nil
            )
        )

        let merged = await client.mergeRuntimeContext(.init())
        XCTAssertEqual(merged.lastRecommendations?.referenceSetID, "set-new")
        XCTAssertEqual(merged.lastRecommendations?.items.count, 1)
        XCTAssertEqual(merged.lastRecommendations?.items.first?.url, "https://example.com/new")
    }

    func testApplyProductsEventIgnoresBlankURLsWhenDerivingRecommendationMemory() async {
        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                tenantID: "demo",
                parentOrigin: URL(string: "https://mobile.example.com")!
            )
        )

        await client.applyProductsEvent(
            BalakunProductsEvent(
                action: "products",
                mode: "replace",
                layout: "cards",
                referenceSetID: "set-new",
                title: nil,
                subtitle: nil,
                items: [
                    BalakunProductItem(
                        position: 1,
                        id: "id-new",
                        name: "New Item",
                        url: "   ",
                        images: nil
                    )
                ],
                memory: nil
            )
        )

        let merged = await client.mergeRuntimeContext(.init())
        XCTAssertNil(merged.lastRecommendations)
    }

    func testApplyProductsEventReplaceWithEmptyItemsClearsRecommendations() async {
        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                tenantID: "demo",
                parentOrigin: URL(string: "https://mobile.example.com")!
            )
        )

        await client.applyProductsEvent(
            BalakunProductsEvent(
                action: "products",
                mode: "replace",
                layout: "cards",
                referenceSetID: "set-seeded",
                title: nil,
                subtitle: nil,
                items: [
                    BalakunProductItem(
                        position: 1,
                        id: "id-seeded",
                        name: "Seed Item",
                        url: "https://example.com/seed",
                        images: nil
                    )
                ],
                memory: nil
            )
        )

        await client.applyProductsEvent(
            BalakunProductsEvent(
                action: "products",
                mode: "replace",
                layout: "cards",
                referenceSetID: "set-seeded",
                title: nil,
                subtitle: nil,
                items: [],
                memory: nil
            )
        )

        let merged = await client.mergeRuntimeContext(.init())
        XCTAssertNil(merged.lastRecommendations)
    }
}

/// In-memory session store used by reset tests.
private actor InMemoryResetSessionStore: BalakunSessionStore {
    private var sessions: [String: BalakunSession] = [:]

    /// Creates in-memory store with optional initial session value.
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
