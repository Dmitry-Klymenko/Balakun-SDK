import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BalakunClient {
    func performDataRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await requestWithRetry {
            let (data, urlResponse) = try await configuration.urlSession.data(for: request)
            return (data, try response(from: urlResponse))
        }
    }

    func performStreamRequest(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await requestWithRetry {
            let (bytes, urlResponse) = try await configuration.urlSession.bytes(for: request)
            return (bytes, try response(from: urlResponse))
        }
    }

    private func requestWithRetry<Value>(
        _ operation: () async throws -> (Value, HTTPURLResponse)
    ) async throws -> (Value, HTTPURLResponse) {
        var attempt = 1
        var backoff = configuration.retryPolicy.initialDelay

        while true {
            do {
                let (value, http) = try await operation()

                if shouldRetry(statusCode: http.statusCode), canRetry(attempt: attempt) {
                    try await sleep(for: serverDelay(from: http, fallback: backoff))
                    attempt += 1
                    backoff = nextBackoff(after: backoff)
                    continue
                }

                return (value, http)
            } catch {
                guard !(error is CancellationError),
                      shouldRetry(error),
                      canRetry(attempt: attempt) else {
                    throw error
                }

                try await sleep(for: backoff)
                attempt += 1
                backoff = nextBackoff(after: backoff)
            }
        }
    }

    private func response(from response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw BalakunSDKError.invalidResponse
        }
        return http
    }

    private func canRetry(attempt: Int) -> Bool {
        attempt < configuration.retryPolicy.maxAttempts
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if case let BalakunSDKError.httpError(status, _) = error {
            return shouldRetry(statusCode: status)
        }

        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func shouldRetry(statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 429, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    private func sleep(for delay: TimeInterval) async throws {
        guard delay > 0 else {
            return
        }

        let nanoseconds = UInt64(delay * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func nextBackoff(after delay: TimeInterval) -> TimeInterval {
        min(
            max(delay * configuration.retryPolicy.multiplier, configuration.retryPolicy.initialDelay),
            configuration.retryPolicy.maxDelay
        )
    }

    private func serverDelay(from response: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        guard let retryAfter = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !retryAfter.isEmpty else {
            return fallback
        }

        if let seconds = TimeInterval(retryAfter) {
            return max(0, min(seconds, configuration.retryPolicy.maxDelay))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        guard let date = formatter.date(from: retryAfter) else {
            return fallback
        }

        let seconds = date.timeIntervalSinceNow
        return max(0, min(seconds, configuration.retryPolicy.maxDelay))
    }
}
