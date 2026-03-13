import Foundation

enum BalakunEventDecoder {
    static func decodeEvents(from message: SSEMessage, decoder: JSONDecoder) -> [BalakunStreamEvent] {
        let primary = decode(event: message, decoder: decoder)
        if case .unknown = primary {
            if let singleFrame = decodeSingleFrame(from: message, decoder: decoder) {
                return [singleFrame]
            }

            if let frames = decodeFrames(from: message, decoder: decoder),
               !frames.isEmpty {
                return frames
            }
        }

        return [primary]
    }
}

extension BalakunEventDecoder {
    private typealias NamedEventDecoder = @Sendable (SSEMessage, JSONDecoder) -> BalakunStreamEvent

    private static let namedEventDecoders: [String: NamedEventDecoder] = [
        "model": { message, decoder in
            decodeKnownEvent(
                BalakunModelEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.model
            )
        },
        "answer_delta": { message, decoder in
            decodeKnownEvent(
                BalakunAnswerDeltaEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.answerDelta
            )
        },
        "reasoning_delta": { message, decoder in
            decodeKnownEvent(
                BalakunReasoningDeltaEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.reasoningDelta
            )
        },
        "tag_event": { message, decoder in
            decodeKnownEvent(
                BalakunTagEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.tag
            )
        },
        "tool_event": { message, decoder in
            decodeKnownEvent(
                BalakunToolEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.tool
            )
        },
        "products": { message, decoder in
            decodeKnownEvent(
                BalakunProductsEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.products
            )
        },
        "present_product": { message, decoder in
            decodeKnownEvent(
                BalakunProductsEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.products
            )
        },
        "navigate": { message, decoder in
            decodeKnownEvent(
                BalakunNavigateEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.navigate
            )
        },
        "client_state": { message, decoder in
            decodeKnownEvent(
                BalakunClientStateEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.clientState
            )
        },
        "tooling_stats": { message, decoder in
            decodeToolingStatsEvent(from: message, decoder: decoder)
        },
        "log_event": { message, decoder in
            decodeKnownEvent(
                BalakunLogEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.logEvent
            )
        },
        "add_to_basket": { message, decoder in
            decodeKnownEvent(
                BalakunAddToBasketEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.addToBasket
            )
        },
        "submit_form": { message, decoder in
            decodeKnownEvent(
                BalakunSubmitFormEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.submitForm
            )
        },
        "conversation_meaningful": { message, decoder in
            decodeKnownEvent(
                BalakunConversationMeaningfulEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.conversationMeaningful
            )
        }
    ]

    private static func decodeSingleFrame(
        from message: SSEMessage,
        decoder: JSONDecoder
    ) -> BalakunStreamEvent? {
        let trimmed = message.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed == "[DONE]" {
            return .done(BalakunDoneEvent(messageID: nil))
        }

        return decodeFrame(
            trimmed,
            sourceEventName: message.event,
            decoder: decoder
        )
    }

    static func decode(event message: SSEMessage, decoder: JSONDecoder) -> BalakunStreamEvent {
        if message.event == "message" {
            return decodeMessageEvent(message)
        }

        if let decoded = decodeNamedEvent(message, decoder: decoder) {
            return decoded
        }

        return unknownEvent(from: message)
    }

    private static func decodeNamedEvent(_ message: SSEMessage, decoder: JSONDecoder) -> BalakunStreamEvent? {
        if let decode = namedEventDecoders[message.event] {
            return decode(message, decoder)
        }

        switch message.event {
        case "done":
            let trimmed = message.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if let framed = decodeFrame(
                trimmed,
                sourceEventName: message.event,
                decoder: decoder
            ) {
                return framed
            }
            return decodeKnownEvent(
                BalakunDoneEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.done
            )
        case "error":
            return decodeKnownEvent(
                BalakunErrorEvent.self,
                from: message,
                decoder: decoder,
                map: BalakunStreamEvent.error
            )
        default:
            return nil
        }
    }

    private static func decodeFrames(
        from message: SSEMessage,
        decoder: JSONDecoder
    ) -> [BalakunStreamEvent]? {
        guard message.data.contains("\n") || message.data.contains("\r") else {
            return nil
        }

        var events: [BalakunStreamEvent] = []
        let rawLines = message.data.components(separatedBy: .newlines)

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            if line == "[DONE]" {
                events.append(.done(BalakunDoneEvent(messageID: nil)))
                continue
            }

            if let decoded = decodeFrame(
                line,
                sourceEventName: message.event,
                decoder: decoder
            ) {
                events.append(decoded)
                continue
            }

            events.append(.unknown(BalakunUnknownEvent(name: message.event, payload: parseUnknownPayload(line))))
        }

        return events.isEmpty ? nil : events
    }

    private static func decodeFrame(
        _ rawLine: String,
        sourceEventName: String,
        decoder: JSONDecoder
    ) -> BalakunStreamEvent? {
        guard let data = rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let payloadObject = (object["data"] as? [String: Any]) ?? object
        let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject)

        if let event = decodeBasicFrame(
            directData: data,
            wrappedData: payloadData != data ? payloadData : nil,
            decoder: decoder
        ) {
            return event
        }

        if let toolingStats = decodeToolingStatsFrame(
            payloadObject: payloadObject,
            rawLine: rawLine,
            decoder: decoder
        ) {
            return toolingStats
        }

        if let productsEvent = decodeProductsFrame(
            object: object,
            data: data,
            sourceEventName: sourceEventName,
            decoder: decoder
        ) {
            return productsEvent
        }

        if let conversational = decodeConversationalFramedEvent(
            payloadObject: payloadObject,
            sourceEventName: sourceEventName
        ) {
            return conversational
        }

        return nil
    }

    private static func decodeFramePayload<T: Decodable>(
        _ type: T.Type,
        directData: Data,
        wrappedData: Data?,
        decoder: JSONDecoder,
        map: (T) -> BalakunStreamEvent
    ) -> BalakunStreamEvent? {
        if let direct = decodeTypedFrame(type, from: directData, decoder: decoder, map: map) {
            return direct
        }
        guard let wrappedData else {
            return nil
        }
        return decodeTypedFrame(type, from: wrappedData, decoder: decoder, map: map)
    }

    private static func decodeBasicFrame(
        directData: Data,
        wrappedData: Data?,
        decoder: JSONDecoder
    ) -> BalakunStreamEvent? {
        if let event = decodeFramePayload(
            BalakunModelEvent.self,
            directData: directData,
            wrappedData: wrappedData,
            decoder: decoder,
            map: BalakunStreamEvent.model
        ) {
            return event
        }
        if let event = decodeFramePayload(
            BalakunLogEvent.self,
            directData: directData,
            wrappedData: wrappedData,
            decoder: decoder,
            map: BalakunStreamEvent.logEvent
        ) {
            return event
        }
        if let event = decodeFramePayload(
            BalakunErrorEvent.self,
            directData: directData,
            wrappedData: wrappedData,
            decoder: decoder,
            map: BalakunStreamEvent.error
        ) {
            return event
        }
        return decodeFramePayload(
            BalakunClientStateEvent.self,
            directData: directData,
            wrappedData: wrappedData,
            decoder: decoder,
            map: BalakunStreamEvent.clientState
        )
    }

    private static func decodeToolingStatsFrame(
        payloadObject: [String: Any],
        rawLine: String,
        decoder: JSONDecoder
    ) -> BalakunStreamEvent? {
        guard payloadObject["llm_calls"] != nil || payloadObject["tools"] != nil else {
            return nil
        }

        let toolingStats = decodeToolingStatsEvent(
            from: SSEMessage(id: nil, event: "tooling_stats", data: rawLine),
            decoder: decoder
        )
        if case .unknown = toolingStats {
            return nil
        }
        return toolingStats
    }

    private static func decodeConversationalFramedEvent(
        payloadObject: [String: Any],
        sourceEventName: String
    ) -> BalakunStreamEvent? {
        if let content = payloadObject["content"] as? String {
            return .answerDelta(
                BalakunAnswerDeltaEvent(
                    content: content,
                    messageID: normalizedOptionalString(payloadObject["messageId"])
                )
            )
        }

        if let reason = normalizedOptionalString(payloadObject["reason"]) {
            return .conversationMeaningful(BalakunConversationMeaningfulEvent(reason: reason))
        }

        guard sourceEventName == "done", isDoneFramePayload(payloadObject) else {
            return nil
        }
        return .done(BalakunDoneEvent(messageID: normalizedOptionalString(payloadObject["messageId"])))
    }

    private static func isDoneFramePayload(_ payloadObject: [String: Any]) -> Bool {
        if payloadObject.isEmpty {
            return true
        }
        if normalizedOptionalString(payloadObject["messageId"]) != nil {
            return true
        }
        return payloadObject["conversationId"] != nil || payloadObject["seq"] != nil
    }

    private static func decodeTypedFrame<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder,
        map: (T) -> BalakunStreamEvent
    ) -> BalakunStreamEvent? {
        guard let payload = try? decoder.decode(type, from: data) else {
            return nil
        }
        return map(payload)
    }

    private static func decodeMessageEvent(_ message: SSEMessage) -> BalakunStreamEvent {
        let trimmed = message.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" {
            return .done(BalakunDoneEvent(messageID: nil))
        }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let choices = object["choices"] as? [[String: Any]],
               let first = choices.first,
               let content = extractChoiceContent(first),
               !content.isEmpty {
                return .answerDelta(BalakunAnswerDeltaEvent(content: content, messageID: nil))
            }
            return .unknown(BalakunUnknownEvent(name: "message", payload: parseUnknownPayload(trimmed)))
        }

        if !trimmed.isEmpty {
            return .answerDelta(BalakunAnswerDeltaEvent(content: trimmed, messageID: nil))
        }

        return .unknown(BalakunUnknownEvent(name: "message", payload: nil))
    }

    private static func extractChoiceContent(_ choice: [String: Any]) -> String? {
        if let delta = choice["delta"] as? [String: Any],
           let content = normalizedMessageContent(delta["content"]) {
            return content
        }
        if let message = choice["message"] as? [String: Any],
           let content = normalizedMessageContent(message["content"]) {
            return content
        }
        return normalizedMessageContent(choice["content"])
    }

    private static func normalizedMessageContent(_ value: Any?) -> String? {
        if let content = value as? String {
            return content
        }
        if let contentArray = value as? [Any] {
            let joined = contentArray.compactMap { segment -> String? in
                if let text = segment as? String {
                    return text
                }
                guard let object = segment as? [String: Any] else {
                    return nil
                }
                if let text = object["text"] as? String {
                    return text
                }
                if let nestedText = object["text"] as? [String: Any],
                   let value = nestedText["value"] as? String {
                    return value
                }
                return nil
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func decodeKnownEvent<T: Decodable>(
        _ type: T.Type,
        from message: SSEMessage,
        decoder: JSONDecoder,
        map: (T) -> BalakunStreamEvent
    ) -> BalakunStreamEvent {
        guard let data = message.data.data(using: .utf8) else {
            return unknownEvent(from: message)
        }
        do {
            return map(try decoder.decode(type, from: data))
        } catch {
            return unknownEvent(from: message)
        }
    }

    private static func decodeToolingStatsEvent(from message: SSEMessage, decoder: JSONDecoder) -> BalakunStreamEvent {
        let strict = decodeKnownEvent(
            BalakunToolingStatsEvent.self,
            from: message,
            decoder: decoder,
            map: BalakunStreamEvent.toolingStats
        )
        if case .toolingStats = strict {
            return strict
        }

        guard let payload = parseJSONObject(message.data) else {
            return unknownEvent(from: message)
        }

        let llmCalls = coerceInt(payload["llm_calls"])
        let tools = coerceToolStats(payload["tools"])
        return .toolingStats(BalakunToolingStatsEvent(llmCalls: llmCalls, tools: tools))
    }

    private static func decodeProductsFrame(
        object: [String: Any],
        data: Data,
        sourceEventName: String,
        decoder: JSONDecoder
    ) -> BalakunStreamEvent? {
        let sourceEvent = sourceEventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let payload = (object["data"] as? [String: Any]) ?? object
        let wrappedPayloadData = (try? JSONSerialization.data(withJSONObject: payload))
        let action = normalizedOptionalString(payload["action"])?.lowercased()
        let hasItemsPayload = payload["items"] != nil || payload["products"] != nil
        let productsEventByName = sourceEvent == "products" || sourceEvent == "present_product"
        let productsEventByAction = action == "products" || action == "present_product"

        guard productsEventByName || productsEventByAction || hasItemsPayload else {
            return nil
        }

        if let strict = decodeFramePayload(
            BalakunProductsEvent.self,
            directData: data,
            wrappedData: wrappedPayloadData != data ? wrappedPayloadData : nil,
            decoder: decoder,
            map: BalakunStreamEvent.products
        ) {
            return strict
        }

        let fallbackAction = action ?? (sourceEvent == "present_product" ? "present_product" : "products")
        guard let normalized = coerceProductsPayload(payload, fallbackAction: fallbackAction),
              let normalizedData = try? JSONSerialization.data(withJSONObject: normalized),
              let decoded = try? decoder.decode(BalakunProductsEvent.self, from: normalizedData) else {
            return nil
        }
        return .products(decoded)
    }

    private static func unknownEvent(from message: SSEMessage) -> BalakunStreamEvent {
        .unknown(BalakunUnknownEvent(name: message.event, payload: parseUnknownPayload(message.data)))
    }
}
