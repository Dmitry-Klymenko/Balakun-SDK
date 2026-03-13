import Foundation

/// Strongly typed analytics metric value.
public enum BalakunAnalyticsValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

/// Analytics signal emitted by the SDK to host-provided callback.
public struct BalakunAnalyticsSignal: Sendable, Equatable {
    public var event: String
    public var metrics: [String: BalakunAnalyticsValue]
    public var timestamp: Date

    public init(event: String, metrics: [String: BalakunAnalyticsValue], timestamp: Date = Date()) {
        self.event = event
        self.metrics = metrics
        self.timestamp = timestamp
    }
}
