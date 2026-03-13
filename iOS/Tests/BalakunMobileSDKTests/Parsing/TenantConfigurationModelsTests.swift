import XCTest
@testable import BalakunMobileSDK

/// Unit tests for tenant configuration model decoding/encoding behavior.
final class TenantConfigurationModelsTests: XCTestCase {
    /// Verifies `BalakunHistoryConfig` decodes `localTtlMonths` into canonical SDK property.
    func testHistoryConfigDecodesLocalTtlMonths() throws {
        let payload = #"{"maxMessages":100,"localTtlMonths":3}"#
        let config = try JSONDecoder().decode(BalakunHistoryConfig.self, from: Data(payload.utf8))

        XCTAssertEqual(config.maxMessages, 100)
        XCTAssertEqual(config.localTtlMonths, 3)
    }

    /// Verifies encoded history config uses canonical JSON key `localTtlMonths`.
    func testHistoryConfigEncodesCanonicalLocalTtlMonthsKey() throws {
        let config = BalakunHistoryConfig(maxMessages: 50, localTtlMonths: 6)
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["localTtlMonths"] as? Int, 6)
        XCTAssertNil(object["localTTlMonths"])
    }
}
