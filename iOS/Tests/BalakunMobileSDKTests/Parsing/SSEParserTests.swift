import XCTest
@testable import BalakunMobileSDK

/// Unit tests for SSE parsing and decoder mapping behavior.
final class SSEParserTests: XCTestCase {
    /// Verifies that an empty line flushes one complete buffered SSE event block.
    func testLineBufferParsesEventBlocks() {
        var buffer = SSELineBuffer()
        XCTAssertNil(buffer.consume(line: "event: model"))
        XCTAssertNil(buffer.consume(line: "data: {\"model\":\"llama-3.3\"}"))

        let message = buffer.consume(line: "")
        XCTAssertEqual(message?.event, "model")
        XCTAssertEqual(message?.data, "{\"model\":\"llama-3.3\"}")
    }

    /// Verifies parser still splits events when transport omits blank separator lines.
    func testLineBufferParsesEventsWithoutBlankSeparatorLines() {
        var buffer = SSELineBuffer()

        XCTAssertNil(buffer.consume(line: "id: msg:0"))
        XCTAssertNil(buffer.consume(line: "event: answer_delta"))
        XCTAssertNil(buffer.consume(line: "data: {\"content\":\"Hello\"}"))

        let first = buffer.consume(line: "id: msg:1")
        XCTAssertEqual(first?.id, "msg:0")
        XCTAssertEqual(first?.event, "answer_delta")
        XCTAssertEqual(first?.data, "{\"content\":\"Hello\"}")

        XCTAssertNil(buffer.consume(line: "event: done"))
        XCTAssertNil(buffer.consume(line: "data: {\"messageId\":\"m1\"}"))

        let second = buffer.finish()
        XCTAssertEqual(second?.id, "msg:1")
        XCTAssertEqual(second?.event, "done")
        XCTAssertEqual(second?.data, "{\"messageId\":\"m1\"}")
    }

    /// Verifies `event` followed by `id` in the same block does not cause an early flush.
    func testLineBufferKeepsEventAndIDInSameBlock() {
        var buffer = SSELineBuffer()

        XCTAssertNil(buffer.consume(line: "event: answer_delta"))
        XCTAssertNil(buffer.consume(line: "id: msg:42"))
        XCTAssertNil(buffer.consume(line: "data: {\"content\":\"Hello\"}"))

        let message = buffer.consume(line: "")
        XCTAssertEqual(message?.event, "answer_delta")
        XCTAssertEqual(message?.id, "msg:42")
        XCTAssertEqual(message?.data, "{\"content\":\"Hello\"}")
    }

    /// Verifies that `[DONE]` generic message is normalized into `.done` event.
    func testDecoderMapsDoneMessage() {
        let decoder = JSONDecoder()
        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "message", data: "[DONE]"),
            decoder: decoder
        )

        guard case .done = event else {
            XCTFail("Expected .done event")
            return
        }
    }

    /// Verifies OpenAI-style delta payloads are normalized into `.answerDelta`.
    func testDecoderMapsOpenAIStyleDeltaMessage() {
        let decoder = JSONDecoder()
        let payload = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"
        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "message", data: payload),
            decoder: decoder
        )

        guard case .answerDelta(let delta) = event else {
            XCTFail("Expected .answerDelta event")
            return
        }

        XCTAssertEqual(delta.content, "hello")
    }

    func testDecoderMapsOpenAIContentArrayMessage() {
        let decoder = JSONDecoder()
        let payload = """
        {"choices":[{"message":{"content":[{"type":"output_text","text":"Hello"},{"type":"output_text","text":" there"}]}}]}
        """
        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "message", data: payload),
            decoder: decoder
        )

        guard case .answerDelta(let delta) = event else {
            XCTFail("Expected .answerDelta event")
            return
        }

        XCTAssertEqual(delta.content, "Hello there")
    }

    func testDecoderDoesNotRenderStructuredMessageJSONAsAssistantText() {
        let decoder = JSONDecoder()
        let payload = #"{"id":"evt-1","object":"chat.completion.chunk","created":1}"#
        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "message", data: payload),
            decoder: decoder
        )

        guard case .unknown(let unknown) = event else {
            XCTFail("Expected .unknown event")
            return
        }

        XCTAssertEqual(unknown.name, "message")
    }

    /// Verifies malformed known-event JSON does not fail stream decoding.
    func testDecoderFallsBackToUnknownForMalformedKnownEvent() {
        let decoder = JSONDecoder()
        let malformedPayload = "{\"content\":42}"
        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "answer_delta", data: malformedPayload),
            decoder: decoder
        )

        guard case .unknown(let payload) = event else {
            XCTFail("Expected .unknown event fallback")
            return
        }
        XCTAssertEqual(payload.name, "answer_delta")
    }

    /// Verifies tooling-stats decoding keeps valid entries and skips malformed ones.
    func testDecoderCoercesToolingStatsWithMixedToolEntries() {
        let decoder = JSONDecoder()
        let payload = """
        {"llm_calls":"7","tools":[
          {"name":"submit_form","ok":true},
          {"name":"bad_tool"},
          {"name":"basket","ok":"false"}
        ]}
        """

        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "tooling_stats", data: payload),
            decoder: decoder
        )

        guard case .toolingStats(let stats) = event else {
            XCTFail("Expected .toolingStats event")
            return
        }

        XCTAssertEqual(stats.llmCalls, 7)
        XCTAssertEqual(stats.tools.count, 2)
        XCTAssertEqual(stats.tools[0].name, "submit_form")
        XCTAssertTrue(stats.tools[0].ok)
        XCTAssertEqual(stats.tools[1].name, "basket")
        XCTAssertFalse(stats.tools[1].ok)
    }

    /// Verifies multiline JSON frames inside a single `done` SSE payload are expanded
    /// into model, answer, and done events in order.
    func testDecoderExpandsMultilineDonePayloadIntoOrderedEvents() {
        let decoder = JSONDecoder()
        let payload = """
        {"model":"cf/@cf/zai-org/glm-4.7-flash","query_language_tag":"und","language_confidence":0.2}
        {"conversationId":"c1","messageId":"m1","seq":1,"ts":1,"t":0.1,"content":"Hello!"}
        {"conversationId":"c1","messageId":"m1","seq":2,"ts":2,"t":0.2}
        """

        let events = BalakunEventDecoder.decodeEvents(
            from: SSEMessage(id: nil, event: "done", data: payload),
            decoder: decoder
        )

        XCTAssertEqual(events.count, 3)

        guard case .model(let model) = events[0] else {
            XCTFail("Expected model event in first frame")
            return
        }
        XCTAssertEqual(model.model, "cf/@cf/zai-org/glm-4.7-flash")

        guard case .answerDelta(let delta) = events[1] else {
            XCTFail("Expected answer delta in second frame")
            return
        }
        XCTAssertEqual(delta.content, "Hello!")
        XCTAssertEqual(delta.messageID, "m1")

        guard case .done(let done) = events[2] else {
            XCTFail("Expected done event in final frame")
            return
        }
        XCTAssertEqual(done.messageID, "m1")
    }

    /// Verifies multiline payload under `conversation_meaningful` can recover log and
    /// answer frames even when strict event decoding fails.
    func testDecoderExpandsMultilineConversationMeaningfulPayload() {
        let decoder = JSONDecoder()
        let payload = """
        {"event_name":"no_context_retrieval","severity":"warn","properties":{"source":"retrieval"}}
        {"conversationId":"c1","messageId":"m2","seq":1,"content":"I can help with basic chat."}
        {"conversationId":"c1","messageId":"m2","seq":2,"reason":"assistant_threshold"}
        """

        let events = BalakunEventDecoder.decodeEvents(
            from: SSEMessage(id: nil, event: "conversation_meaningful", data: payload),
            decoder: decoder
        )

        XCTAssertEqual(events.count, 3)

        guard case .logEvent(let logEvent) = events[0] else {
            XCTFail("Expected log_event in first frame")
            return
        }
        XCTAssertEqual(logEvent.eventName, "no_context_retrieval")

        guard case .answerDelta(let delta) = events[1] else {
            XCTFail("Expected answer delta in second frame")
            return
        }
        XCTAssertEqual(delta.content, "I can help with basic chat.")

        guard case .conversationMeaningful(let meaningful) = events[2] else {
            XCTFail("Expected conversation meaningful marker in third frame")
            return
        }
        XCTAssertEqual(meaningful.reason, "assistant_threshold")
    }

    /// Verifies `present_product` alias is decoded as a products event.
    func testDecoderMapsPresentProductAliasToProductsEvent() {
        let decoder = JSONDecoder()
        let payload = """
        {"action":"present_product","items":[{"name":"Plan A","url":"https://example.com/a"}]}
        """

        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "present_product", data: payload),
            decoder: decoder
        )

        guard case .products(let products) = event else {
            XCTFail("Expected products event")
            return
        }
        XCTAssertEqual(products.action, "present_product")
        XCTAssertEqual(products.items.count, 1)
        XCTAssertEqual(products.items.first?.name, "Plan A")
    }

    /// Verifies multiline `done` payload can surface framed products events
    /// that include image fields.
    func testDecoderExpandsMultilineDonePayloadWithProductsFrame() {
        let decoder = JSONDecoder()
        let productsFrame =
            "{\"action\":\"products\",\"layout\":\"cards\",\"items\":[{\"name\":\"Blue Dress\"," +
            "\"url\":\"https://example.com/p/1\",\"images\":[\"https://example.com/i/1.webp\"]}]}"
        let payload = """
        {"model":"cf/@cf/zai-org/glm-4.7-flash"}
        \(productsFrame)
        {"conversationId":"c1","messageId":"m1","seq":3}
        """

        let events = BalakunEventDecoder.decodeEvents(
            from: SSEMessage(id: nil, event: "done", data: payload),
            decoder: decoder
        )

        XCTAssertEqual(events.count, 3)

        guard case .products(let products) = events[1] else {
            XCTFail("Expected products event in second frame")
            return
        }
        XCTAssertEqual(products.action, "products")
        XCTAssertEqual(products.items.count, 1)
        XCTAssertEqual(products.items.first?.name, "Blue Dress")
        XCTAssertEqual(products.items.first?.images?.first, "https://example.com/i/1.webp")
    }

    /// Verifies framed wrapper payloads (`{"data": {...}}`) are decoded into typed events.
    func testDecoderExpandsWrappedFramedPayloads() {
        let decoder = JSONDecoder()
        let payload = """
        {"data":{"event_name":"no_context_retrieval","severity":"warn","properties":{"source":"retrieval"}}}
        {"data":{"conversationId":"c1","messageId":"m2","seq":1,"content":"Wrapped content works."}}
        {"data":{"conversationId":"c1","messageId":"m2","seq":2}}
        """

        let events = BalakunEventDecoder.decodeEvents(
            from: SSEMessage(id: nil, event: "done", data: payload),
            decoder: decoder
        )

        XCTAssertEqual(events.count, 3)

        guard case .logEvent(let logEvent) = events[0] else {
            XCTFail("Expected log_event in first frame")
            return
        }
        XCTAssertEqual(logEvent.eventName, "no_context_retrieval")

        guard case .answerDelta(let delta) = events[1] else {
            XCTFail("Expected answer delta in second frame")
            return
        }
        XCTAssertEqual(delta.content, "Wrapped content works.")
        XCTAssertEqual(delta.messageID, "m2")

        guard case .done(let done) = events[2] else {
            XCTFail("Expected done event in third frame")
            return
        }
        XCTAssertEqual(done.messageID, "m2")
    }

    /// Verifies non-integral `llm_calls` payload values are rejected instead of truncated.
    func testDecoderDoesNotTruncateNonIntegralToolingStatsCounts() {
        let decoder = JSONDecoder()
        let payload = """
        {"llm_calls":1.75,"tools":[{"name":"submit_form","ok":true}]}
        """

        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "tooling_stats", data: payload),
            decoder: decoder
        )

        guard case .toolingStats(let stats) = event else {
            XCTFail("Expected .toolingStats event")
            return
        }

        XCTAssertNil(stats.llmCalls)
        XCTAssertEqual(stats.tools.count, 1)
        XCTAssertEqual(stats.tools.first?.name, "submit_form")
    }

    /// Verifies tooling-stats bool coercion accepts only strict numeric 0/1 values.
    func testDecoderRejectsInvalidNumericToolBoolValues() {
        let decoder = JSONDecoder()
        let payload = """
        {"llm_calls":1,"tools":[
          {"name":"strict-true","ok":1},
          {"name":"strict-false","ok":0},
          {"name":"invalid","ok":2}
        ]}
        """

        let event = BalakunEventDecoder.decode(
            event: SSEMessage(id: nil, event: "tooling_stats", data: payload),
            decoder: decoder
        )

        guard case .toolingStats(let stats) = event else {
            XCTFail("Expected .toolingStats event")
            return
        }

        XCTAssertEqual(stats.tools.count, 2)
        XCTAssertEqual(stats.tools[0].name, "strict-true")
        XCTAssertTrue(stats.tools[0].ok)
        XCTAssertEqual(stats.tools[1].name, "strict-false")
        XCTAssertFalse(stats.tools[1].ok)
    }

    /// Verifies wrapped single-line payloads are decoded even without newline-delimited frames.
    func testDecoderParsesWrappedSingleLineDonePayload() {
        let decoder = JSONDecoder()
        let payload = #"{"data":{"conversationId":"c1","messageId":"m1","seq":1}}"#

        let events = BalakunEventDecoder.decodeEvents(
            from: SSEMessage(id: nil, event: "done", data: payload),
            decoder: decoder
        )

        XCTAssertEqual(events.count, 1)
        guard case .done(let done) = events[0] else {
            XCTFail("Expected .done event")
            return
        }
        XCTAssertEqual(done.messageID, "m1")
    }

    /// Verifies product image deduplication keeps first-seen order.
    func testDecoderCoercedProductsKeepFirstImageOrder() {
        let decoder = JSONDecoder()
        let payload = """
        {"action":"products","items":[{"title":"Item A","images":["https://cdn/i2.webp","https://cdn/i1.webp","https://cdn/i2.webp"]}]}
        """

        let events = BalakunEventDecoder.decodeEvents(
            from: SSEMessage(id: nil, event: "done", data: payload),
            decoder: decoder
        )

        XCTAssertEqual(events.count, 1)
        guard case .products(let products) = events[0] else {
            XCTFail("Expected .products event")
            return
        }

        XCTAssertEqual(
            products.items.first?.images,
            ["https://cdn/i2.webp", "https://cdn/i1.webp"]
        )
    }
}
