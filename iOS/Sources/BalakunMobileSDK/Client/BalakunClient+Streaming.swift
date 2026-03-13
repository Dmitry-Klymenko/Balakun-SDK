import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BalakunClient {
    func streamMessage(
        query: String,
        context: BalakunRuntimeContext,
        continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation
    ) async throws {
        _ = try await bootstrap()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw BalakunSDKError.invalidConfiguration("query must not be empty")
        }

        var requestContext = mergeRuntimeContext(context)
        requestContext.pageURL = resolvePageURL(for: requestContext)
        var activeSession = try await ensureSessionToken()
        let clientID = currentClientID()
        let messageID = UUID().uuidString

        func chatPayload(for session: BalakunSession) throws -> Data {
            try buildChatPayload(
                query: trimmedQuery,
                messageID: messageID,
                session: session,
                context: requestContext
            )
        }

        emitChatStart(context: requestContext)
        emitMessageSentAnalytics(queryLength: trimmedQuery.count, context: requestContext)

        var didEmitDone = false
        var payload = try chatPayload(for: activeSession)
        let streamContext = StreamAttemptContext(
            requestContext: requestContext,
            clientID: clientID,
            continuation: continuation
        )

        for attempt in 0..<2 {
            let recoveredSession = try await runStreamAttempt(
                payload: payload,
                session: activeSession,
                allowSessionRecovery: attempt == 0,
                context: streamContext,
                didEmitDone: &didEmitDone
            )

            if let recoveredSession {
                activeSession = recoveredSession
                payload = try chatPayload(for: activeSession)
                continue
            }

            return
        }

        throw BalakunSDKError.sessionUnavailable
    }

    private func runStreamAttempt(
        payload: Data,
        session: BalakunSession,
        allowSessionRecovery: Bool,
        context: StreamAttemptContext,
        didEmitDone: inout Bool
    ) async throws -> BalakunSession? {
        let request = try await buildChatRequest(
            streamURL: resolveChatURL(),
            payload: payload,
            session: session,
            clientID: context.clientID,
            pageURL: context.requestContext.pageURL
        )

        let (bytes, http) = try await performStreamRequest(request)

        let isUnauthorized = http.statusCode == 401 || http.statusCode == 403
        if isUnauthorized, allowSessionRecovery {
            return try await recoverSessionAfterUnauthorized(context: context.requestContext)
        }

        guard (200...299).contains(http.statusCode) else {
            let body = try await collectBody(from: bytes)
            emitHTTPErrorAnalytics(statusCode: http.statusCode, context: context.requestContext)
            throw BalakunSDKError.httpError(status: http.statusCode, body: body)
        }

        let contentType = http.value(forHTTPHeaderField: BalakunRequestHeader.contentType) ?? ""
        guard contentType.lowercased().contains(BalakunContentType.eventStream) else {
            let body = try await collectBody(from: bytes)
            emitAutoAnalytics(
                event: BalakunAnalyticsEventName.chatError,
                metrics: [BalakunAnalyticsKey.errorType: .string("invalid_content_type")],
                context: context.requestContext
            )
            throw BalakunSDKError.invalidContentType(
                expected: BalakunContentType.eventStream,
                actual: "\(contentType) | body: \(body)"
            )
        }

        try await consumeEventStreamBytes(
            bytes,
            continuation: context.continuation,
            context: context.requestContext,
            didEmitDone: &didEmitDone
        )

        if !didEmitDone {
            context.continuation.yield(.done(BalakunDoneEvent(messageID: nil)))
        }
        return nil
    }

    func recoverSessionAfterUnauthorized(context: BalakunRuntimeContext) async throws -> BalakunSession {
        do {
            let refreshed = try await refreshSessionToken()
            if refreshed, let latestSession = session {
                return latestSession
            }
        } catch {
            // If refresh transport fails, fall back to full session creation.
        }

        let recreated = try await createSessionToken()
        await setSession(recreated)
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatSessionCreated,
            metrics: [BalakunAnalyticsKey.sessionID: .string(recreated.conversationID)],
            context: context
        )
        return recreated
    }

    private func emitHTTPErrorAnalytics(statusCode: Int, context: BalakunRuntimeContext) {
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatStreamError,
            metrics: [BalakunAnalyticsKey.errorType: .string("http_\(statusCode)")],
            context: context
        )
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatError,
            metrics: [
                BalakunAnalyticsKey.errorType: .string("http_error"),
                BalakunAnalyticsKey.status: .number(Double(statusCode))
            ],
            context: context
        )
    }

    private func consumeEventStreamBytes(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation,
        context: BalakunRuntimeContext,
        didEmitDone: inout Bool
    ) async throws {
        var state = EventStreamState(didEmitDone: didEmitDone)

        for try await byte in bytes {
            if Task.isCancelled {
                throw CancellationError()
            }

            if try await consumeLineBreak(
                byte,
                state: &state,
                continuation: continuation,
                context: context
            ) {
                continue
            }

            state.previousWasCR = false
            state.currentLine.append(byte)
        }

        try await flushLine(
            state: &state,
            continuation: continuation,
            context: context
        )
        if let finalMessage = state.lineBuffer.finish() {
            try await emit(
                message: finalMessage,
                continuation: continuation,
                context: context,
                didEmitDone: &state.didEmitDone
            )
        }
        didEmitDone = state.didEmitDone
    }

    private func consumeLineBreak(
        _ byte: UInt8,
        state: inout EventStreamState,
        continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation,
        context: BalakunRuntimeContext
    ) async throws -> Bool {
        switch byte {
        case 0x0D:
            try await commitLine(
                state: &state,
                continuation: continuation,
                context: context
            )
            state.previousWasCR = true
            return true
        case 0x0A:
            guard !state.previousWasCR else {
                state.previousWasCR = false
                return true
            }
            try await commitLine(
                state: &state,
                continuation: continuation,
                context: context
            )
            return true
        default:
            return false
        }
    }

    private func flushLine(
        state: inout EventStreamState,
        continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation,
        context: BalakunRuntimeContext
    ) async throws {
        guard !state.currentLine.isEmpty else {
            return
        }
        try await commitLine(
            state: &state,
            continuation: continuation,
            context: context
        )
    }

    private func commitLine(
        state: inout EventStreamState,
        continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation,
        context: BalakunRuntimeContext
    ) async throws {
        defer { state.currentLine.removeAll(keepingCapacity: true) }
        let line = String(bytes: state.currentLine, encoding: .utf8) ?? ""
        if let message = state.lineBuffer.consume(line: line) {
            try await emit(
                message: message,
                continuation: continuation,
                context: context,
                didEmitDone: &state.didEmitDone
            )
        }
    }

    private func emit(
        message: SSEMessage,
        continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation,
        context: BalakunRuntimeContext,
        didEmitDone: inout Bool
    ) async throws {
        let streamEvents = BalakunEventDecoder.decodeEvents(from: message, decoder: decoder)
        try await emitDecodedStreamEvents(
            streamEvents,
            continuation: continuation,
            context: context,
            didEmitDone: &didEmitDone
        )
    }

    private func emitDecodedStreamEvents(
        _ streamEvents: [BalakunStreamEvent],
        continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation,
        context: BalakunRuntimeContext,
        didEmitDone: inout Bool
    ) async throws {
        for streamEvent in streamEvents {
            if case .done = streamEvent {
                if didEmitDone {
                    continue
                }
                didEmitDone = true
            }
            applyStreamEventSideEffects(streamEvent, context: context)
            continuation.yield(streamEvent)
        }
    }

    func replaceActiveStreamTask(_ task: Task<Void, Never>, id: UUID, order: Int) {
        guard order >= activeStreamTaskOrder else {
            task.cancel()
            return
        }
        activeStreamTask?.cancel()
        activeStreamTask = task
        activeStreamTaskID = id
        activeStreamTaskOrder = order
    }

    func clearActiveStreamTask(id: UUID) {
        guard activeStreamTaskID == id else {
            return
        }
        activeStreamTask = nil
        activeStreamTaskID = nil
    }

    func emitChatStart(context: BalakunRuntimeContext) {
        guard !hasSentFirstMessage else {
            return
        }

        hasSentFirstMessage = true
        emitAutoAnalytics(event: BalakunAnalyticsEventName.chatStarted, context: context)
    }

    func emitMessageSentAnalytics(queryLength: Int, context: BalakunRuntimeContext) {
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatMessageSent,
            metrics: [BalakunAnalyticsKey.messageLength: .number(Double(queryLength))],
            context: context
        )
    }
}

private struct StreamAttemptContext {
    let requestContext: BalakunRuntimeContext
    let clientID: String
    let continuation: AsyncThrowingStream<BalakunStreamEvent, Error>.Continuation
}

private struct EventStreamState {
    var lineBuffer = SSELineBuffer()
    var currentLine = Data()
    var previousWasCR = false
    var didEmitDone: Bool
}
