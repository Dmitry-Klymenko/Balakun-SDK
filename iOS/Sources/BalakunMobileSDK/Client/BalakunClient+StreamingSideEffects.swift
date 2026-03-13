import Foundation

extension BalakunClient {
    func applyStreamEventSideEffects(_ event: BalakunStreamEvent, context: BalakunRuntimeContext) {
        switch event {
        case .model(let payload):
            applyModelEvent(payload)

        case .products(let payload):
            applyProductsEvent(payload)

        case .clientState(let payload):
            applyClientStateCommands(payload.commands)

        default:
            applyAnalyticsSideEffects(event, context: context)
        }
    }

    func applyAnalyticsSideEffects(_ event: BalakunStreamEvent, context: BalakunRuntimeContext) {
        switch event {
        case .toolingStats(let payload):
            emitToolingStatsAnalytics(payload, context: context)

        case .logEvent(let payload):
            emitLogEventAnalytics(payload, context: context)

        case .navigate(let payload):
            emitNavigateAnalytics(payload, context: context)

        case .addToBasket(let payload):
            emitAddToBasketAnalytics(payload, context: context)

        case .submitForm(let payload):
            emitSubmitFormAnalytics(payload, context: context)

        case .conversationMeaningful(let payload):
            emitConversationMeaningfulAnalytics(payload, context: context)

        case .error(let payload):
            emitErrorAnalytics(payload, context: context)

        case .model, .products, .clientState, .answerDelta, .reasoningDelta, .tag, .tool, .done, .unknown:
            break
        }
    }

    func applyModelEvent(_ payload: BalakunModelEvent) {
        activeModelName = payload.model
        activeLanguageTag = payload.queryLanguageTag
    }

    func applyProductsEvent(_ payload: BalakunProductsEvent) {
        if let memory = payload.memory {
            retainedRecommendations = memory
            return
        }

        let isReplaceMode = payload.mode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "replace"

        if payload.items.isEmpty {
            if isReplaceMode {
                retainedRecommendations = nil
            }
            return
        }

        // Some gateways emit products without `memory`; derive conservative memory to avoid stale context.
        let fallbackItems = payload.items.compactMap { item -> BalakunRecommendationItem? in
            guard let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                return nil
            }
            return BalakunRecommendationItem(position: item.position, name: item.name, url: url)
        }
        guard !fallbackItems.isEmpty else {
            if isReplaceMode {
                retainedRecommendations = nil
            }
            return
        }

        retainedRecommendations = BalakunRecommendationMemory(
            referenceSetID: payload.referenceSetID,
            items: fallbackItems
        )
    }

    func emitToolingStatsAnalytics(_ payload: BalakunToolingStatsEvent, context: BalakunRuntimeContext) {
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatToolingStats,
            metrics: [
                BalakunAnalyticsKey.llmCalls: .number(Double(payload.llmCalls ?? 0)),
                BalakunAnalyticsKey.toolsOk: .number(Double(payload.tools.filter { $0.ok }.count)),
                BalakunAnalyticsKey.toolsFailed: .number(Double(payload.tools.filter { !$0.ok }.count)),
                BalakunAnalyticsKey.modelName: analyticsString(activeModelName)
            ],
            context: context
        )

        for tool in payload.tools {
            emitAutoAnalytics(
                event: BalakunAnalyticsEventName.chatToolCalled,
                metrics: [
                    BalakunAnalyticsKey.toolName: .string(tool.name),
                    BalakunAnalyticsKey.toolStatus: .string(tool.ok ? "ok" : "failed"),
                    BalakunAnalyticsKey.modelName: analyticsString(activeModelName)
                ],
                context: context
            )
        }
    }

    func emitLogEventAnalytics(_ payload: BalakunLogEvent, context: BalakunRuntimeContext) {
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatLogEvent,
            metrics: [
                BalakunAnalyticsKey.errorType: .string([payload.eventName, payload.severity].compactMap { $0 }.joined(separator: ":")),
                BalakunAnalyticsKey.logEventCode: .string(payload.eventName),
                BalakunAnalyticsKey.logEventSeverity: analyticsString(payload.severity),
                BalakunAnalyticsKey.logEventSource: analyticsString(logEventSource(from: payload))
            ],
            context: context
        )
    }

    func emitNavigateAnalytics(_ payload: BalakunNavigateEvent, context: BalakunRuntimeContext) {
        let target = URL(string: payload.url)
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatNavigationCommand,
            metrics: [
                BalakunAnalyticsKey.navAllowed: .bool(true),
                BalakunAnalyticsKey.navMode: analyticsString(payload.mode),
                BalakunAnalyticsKey.navStage: .string("received"),
                BalakunAnalyticsKey.linkSource: .string("llm_navigation"),
                BalakunAnalyticsKey.linkTargetHost: analyticsString(target?.host?.lowercased()),
                BalakunAnalyticsKey.linkTargetPath: analyticsString(target?.path)
            ],
            context: context
        )
    }

    func emitAddToBasketAnalytics(_ payload: BalakunAddToBasketEvent, context: BalakunRuntimeContext) {
        let target = payload.url.flatMap(URL.init(string:))
        if payload.ok == true {
            emitAutoAnalytics(
                event: BalakunAnalyticsEventName.chatAddToBasket,
                metrics: [
                    BalakunAnalyticsKey.addToBasketSource: analyticsString(payload.source),
                    BalakunAnalyticsKey.addToBasketStatus: .string("ok"),
                    BalakunAnalyticsKey.productPosition: payload.position.map { .number(Double($0)) } ?? .null,
                    BalakunAnalyticsKey.linkTargetHost: analyticsString(target?.host?.lowercased()),
                    BalakunAnalyticsKey.linkTargetPath: analyticsString(target?.path)
                ],
                context: context
            )
            return
        }

        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatError,
            metrics: [
                BalakunAnalyticsKey.errorType: .string("add_to_basket_failed"),
                BalakunAnalyticsKey.status: .string(payload.ok == false ? "failed" : "unknown")
            ],
            context: context
        )
    }

    func emitSubmitFormAnalytics(_ payload: BalakunSubmitFormEvent, context: BalakunRuntimeContext) {
        if payload.ok == true {
            emitAutoAnalytics(event: BalakunAnalyticsEventName.chatSubmitForm, context: context)
            return
        }

        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatError,
            metrics: [
                BalakunAnalyticsKey.errorType: .string("submit_form_failed"),
                BalakunAnalyticsKey.status: .string(payload.ok == false ? "failed" : "unknown")
            ],
            context: context
        )
    }

    func emitConversationMeaningfulAnalytics(
        _ payload: BalakunConversationMeaningfulEvent,
        context: BalakunRuntimeContext
    ) {
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatConversationMeaningful,
            metrics: [BalakunAnalyticsKey.errorType: .string(payload.reason)],
            context: context
        )
    }

    func emitErrorAnalytics(_ payload: BalakunErrorEvent, context: BalakunRuntimeContext) {
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatStreamError,
            metrics: [BalakunAnalyticsKey.errorType: .string("stream_error")],
            context: context
        )
        emitAutoAnalytics(
            event: BalakunAnalyticsEventName.chatError,
            metrics: [
                BalakunAnalyticsKey.errorType: .string("stream_error"),
                BalakunAnalyticsKey.status: payload.status.map { .number(Double($0)) } ?? .null
            ],
            context: context
        )
    }

    func applyClientStateCommands(_ commands: [BalakunClientStateCommand]) {
        var state = retainedRetailState ?? BalakunRetailState()

        for command in commands {
            applyClientStateCommand(command, to: &state)
        }

        retainedRetailState = state
    }

    func applyClientStateCommand(_ command: BalakunClientStateCommand, to state: inout BalakunRetailState) {
        guard command.op == "set" || command.op == "delete" else {
            return
        }
        let isDelete = command.op == "delete"

        if applyStringClientStateCommand(command, isDelete: isDelete, to: &state) {
            return
        }
        if applyIntegerClientStateCommand(command, isDelete: isDelete, to: &state) {
            return
        }

        guard command.key == "filters" else {
            return
        }
        state.filters = isDelete ? nil : command.value?.arrayValue?.compactMap { $0.stringValue }
    }

    func applyStringClientStateCommand(
        _ command: BalakunClientStateCommand,
        isDelete: Bool,
        to state: inout BalakunRetailState
    ) -> Bool {
        let nextValue = isDelete ? nil : command.value?.stringValue

        switch command.key {
        case "active_reference_set_id":
            state.activeReferenceSetID = nextValue
        case "memory_session_id":
            state.memorySessionID = nextValue
        case "memory_page_url":
            state.memoryPageURL = nextValue
        case "memory_generated_at":
            state.memoryGeneratedAt = nextValue
        case "selected_product_url":
            state.selectedProductURL = nextValue
        case "last_viewed_category":
            state.lastViewedCategory = nextValue
        default:
            return false
        }

        return true
    }

    func applyIntegerClientStateCommand(
        _ command: BalakunClientStateCommand,
        isDelete: Bool,
        to state: inout BalakunRetailState
    ) -> Bool {
        guard command.key == "selected_position" else {
            return false
        }
        state.selectedPosition = isDelete ? nil : command.value?.intValue
        return true
    }

    func mergeRuntimeContext(_ context: BalakunRuntimeContext) -> BalakunRuntimeContext {
        var merged = context

        if merged.lastRecommendations == nil {
            merged.lastRecommendations = retainedRecommendations
        }

        if merged.retailState == nil {
            merged.retailState = retainedRetailState
        }

        if merged.uiCapabilities == nil {
            merged.uiCapabilities = [
                "can_navigate": true,
                "can_submit_form": true
            ]
        }

        if merged.consentState == nil {
            merged.consentState = "unknown"
        }

        if merged.activeSection == nil,
           let screenName = merged.screenName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !screenName.isEmpty {
            merged.activeSection = screenName
        }

        return merged
    }
}
