import Foundation
import XCTest
@testable import BalakunMobileSDK

/// Unit tests for explicit runtime page URL normalization.
final class BalakunClientPageURLTests: XCTestCase {
    /// Verifies explicit relative `pageURL` values are normalized to absolute URLs.
    func testResolvePageURLNormalizesExplicitRelativePath() async {
        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                baseURL: URL(string: "https://balakun.waybeam.ai")!,
                tenantID: "demo",
                parentOrigin: URL(string: "https://mobile.example.com")!,
                defaultParentPath: "/app"
            )
        )

        let resolved = await client.resolvePageURL(
            for: BalakunRuntimeContext(pageURL: "checkout/details?step=2#composer")
        )

        XCTAssertEqual(resolved, "https://mobile.example.com/checkout/details?step=2")
    }

    /// Verifies explicit absolute `pageURL` values keep host/query and drop fragment.
    func testResolvePageURLKeepsExplicitAbsoluteURL() async {
        let client = BalakunClient(
            configuration: BalakunSDKConfiguration(
                baseURL: URL(string: "https://balakun.waybeam.ai")!,
                tenantID: "demo",
                parentOrigin: URL(string: "https://mobile.example.com")!
            )
        )

        let resolved = await client.resolvePageURL(
            for: BalakunRuntimeContext(pageURL: "https://shop.example.org/app/chat?tab=1#bottom")
        )

        XCTAssertEqual(resolved, "https://shop.example.org/app/chat?tab=1")
    }
}
