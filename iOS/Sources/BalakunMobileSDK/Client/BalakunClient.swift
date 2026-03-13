import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Main SDK entry point for session handling, transport orchestration, and SSE event normalization.
public actor BalakunClient {
    let configuration: BalakunSDKConfiguration
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    var tenantConfig: BalakunPublicTenantConfig?
    var session: BalakunSession?
    var hasSentFirstMessage = false
    var activeStreamTask: Task<Void, Never>?
    var activeStreamTaskID: UUID?
    var activeStreamTaskOrder = 0
    var nextStreamOrder = 0
    var hasLoadedSessionFromStore = false

    var retainedRecommendations: BalakunRecommendationMemory?
    var retainedRetailState: BalakunRetailState?
    var activeModelName: String?
    var activeLanguageTag: String?
    var generatedClientID: String?

    public init(configuration: BalakunSDKConfiguration) {
        self.configuration = configuration

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder

        let encoder = JSONEncoder()
        self.encoder = encoder
    }

    public func bootstrap() async throws -> BalakunPublicTenantConfig {
        if let tenantConfig {
            return tenantConfig
        }

        await loadPersistedSessionIfNeeded()

        guard !configuration.tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BalakunSDKError.invalidConfiguration("tenantID must not be empty")
        }

        let config = try await fetchTenantConfig()
        tenantConfig = applyConfigDefaults(config)
        return tenantConfig!
    }

    public func currentSession() -> BalakunSession? {
        session
    }

    public func cancelActiveStream() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeStreamTaskID = nil
    }

    public func resetSession() async {
        cancelActiveStream()
        await setSession(nil)
        hasSentFirstMessage = false
        retainedRecommendations = nil
        retainedRetailState = nil
        activeModelName = nil
        activeLanguageTag = nil
        hasLoadedSessionFromStore = true
    }

    public func emitAnalytics(event: String, metrics: [String: BalakunAnalyticsValue] = [:]) {
        configuration.analyticsHandler?(BalakunAnalyticsSignal(event: event, metrics: metrics))
    }

    public func sendMessage(
        _ query: String,
        context: BalakunRuntimeContext = .init()
    ) -> AsyncThrowingStream<BalakunStreamEvent, Error> {
        let streamTaskID = UUID()
        nextStreamOrder += 1
        let streamOrder = nextStreamOrder
        return AsyncThrowingStream<BalakunStreamEvent, Error> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    try await self.streamMessage(query: query, context: context, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                await self.clearActiveStreamTask(id: streamTaskID)
            }

            continuation.onTermination = { _ in
                task.cancel()
            }

            replaceActiveStreamTask(task, id: streamTaskID, order: streamOrder)
        }
    }

    public func submitFeedback(
        messageID: String,
        rating: Int? = nil,
        reasonCode: String? = nil,
        reasonText: String? = nil
    ) async throws {
        guard !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BalakunSDKError.invalidConfiguration("messageID must not be empty")
        }

        try await submitFeedbackRequest(
            messageID: messageID,
            rating: rating,
            reasonCode: reasonCode,
            reasonText: reasonText
        )

        guard let rating else {
            return
        }

        emitAnalytics(
            event: BalakunAnalyticsEventName.chatMessageRated,
            metrics: [
                BalakunAnalyticsKey.messageID: .string(messageID),
                BalakunAnalyticsKey.rating: .number(Double(rating))
            ]
        )
    }
}
