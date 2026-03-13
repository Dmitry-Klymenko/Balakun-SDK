import Foundation

struct SSEMessage: Equatable {
    var id: String?
    var event: String
    var data: String
}

struct SSELineBuffer {
    private var eventName: String?
    private var eventID: String?
    private var dataLines: [String] = []

    mutating func consume(line rawLine: String) -> SSEMessage? {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))

        if line.isEmpty {
            return flush()
        }

        if line.hasPrefix(":") {
            return nil
        }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        let valuePart: String
        if parts.count > 1 {
            let tail = String(parts[1])
            valuePart = tail.hasPrefix(" ") ? String(tail.dropFirst()) : tail
        } else {
            valuePart = ""
        }

        // URLSession.AsyncBytes.lines can omit blank separators for SSE frames.
        // When a new header starts while payload is buffered, flush previous event first.
        if shouldFlushBeforeApplying(field: field),
           let message = flush() {
            apply(field: field, valuePart: valuePart)
            return message
        }

        apply(field: field, valuePart: valuePart)
        return nil
    }

    private mutating func apply(field: String, valuePart: String) {
        switch field {
        case "event":
            eventName = valuePart
        case "id":
            eventID = valuePart
        case "data":
            dataLines.append(valuePart)
        default:
            break
        }
    }

    private func shouldFlushBeforeApplying(field: String) -> Bool {
        switch field {
        case "id":
            // Flush on `id` only when payload lines already exist.
            // This preserves valid blocks where `event` arrives before `id`.
            return !dataLines.isEmpty
        case "event":
            return !dataLines.isEmpty
        default:
            return false
        }
    }

    mutating func finish() -> SSEMessage? {
        flush()
    }

    private mutating func flush() -> SSEMessage? {
        if eventID == nil && eventName == nil && dataLines.isEmpty {
            return nil
        }

        let message = SSEMessage(
            id: eventID,
            event: eventName ?? "message",
            data: dataLines.joined(separator: "\n")
        )

        eventName = nil
        eventID = nil
        dataLines = []
        return message
    }
}
