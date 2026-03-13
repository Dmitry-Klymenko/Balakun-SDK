import Foundation
import XCTest
@testable import BalakunMobileSDK

final class SSEParserProductsTests: XCTestCase {
    func testDecoderPreservesProductsMemoryInWrappedPayload() {
        let decoder = JSONDecoder()
        let payload = """
        {"data":{
          "action":"products",
          "mode":"replace",
          "reference_set_id":"set-1",
          "items":[{"position":1,"name":"Item 1","url":"https://example.com/p/1"}],
          "memory":{
            "reference_set_id":"set-1",
            "items":[{"position":1,"name":"Item 1","url":"https://example.com/p/1"}]
          }
        }}
        """

        let events = BalakunEventDecoder.decodeEvents(
            from: SSEMessage(id: nil, event: "done", data: payload),
            decoder: decoder
        )

        XCTAssertEqual(events.count, 1)
        guard case .products(let products) = events[0] else {
            XCTFail("Expected products event")
            return
        }

        XCTAssertEqual(products.action, "products")
        XCTAssertEqual(products.items.count, 1)
        XCTAssertEqual(products.memory?.referenceSetID, "set-1")
        XCTAssertEqual(products.memory?.items.count, 1)
        XCTAssertEqual(products.memory?.items.first?.url, "https://example.com/p/1")
    }
}
