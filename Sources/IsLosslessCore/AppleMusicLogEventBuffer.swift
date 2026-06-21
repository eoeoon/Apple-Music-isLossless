import Foundation

public struct AppleMusicLogEvent: Equatable, Sendable {
    public let date: Date
    public let message: String

    public init(date: Date, message: String) {
        self.date = date
        self.message = message
    }
}

public struct AppleMusicLogEventBuffer: Sendable {
    private var lineBuffer = ""
    private var currentEventDate: Date?
    private var currentEventLines: [String] = []

    public init() {}

    public mutating func ingest(_ text: String, date: Date = Date()) -> [AppleMusicLogEvent] {
        lineBuffer += text
        var events: [AppleMusicLogEvent] = []

        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newlineIndex])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])
            events.append(contentsOf: consumeLine(line, date: date))
        }

        return events
    }

    public mutating func reset() {
        lineBuffer.removeAll()
        currentEventDate = nil
        currentEventLines.removeAll()
    }

    public func currentEntry(date: Date = Date()) -> AppleMusicLogEvent? {
        guard !currentEventLines.isEmpty else {
            return nil
        }

        let message = currentEventLines.joined(separator: "\n")
        guard Self.isRelevantMessage(message) else {
            return nil
        }

        return AppleMusicLogEvent(date: currentEventDate ?? date, message: message)
    }

    private mutating func consumeLine(_ line: String, date: Date) -> [AppleMusicLogEvent] {
        if Self.isLogHeader(line) {
            let flushedEvent = flushCurrentEvent(date: date)
            currentEventDate = Self.logHeaderDate(line) ?? date
            currentEventLines = [line]
            let completedHeaderEvent = flushCurrentEventIfComplete(date: date)
            return [flushedEvent, completedHeaderEvent].compactMap { $0 }
        }

        guard !currentEventLines.isEmpty else {
            return []
        }

        currentEventLines.append(line)
        return flushCurrentEventIfComplete(date: date).map { [$0] } ?? []
    }

    private mutating func flushCurrentEventIfComplete(date: Date) -> AppleMusicLogEvent? {
        guard !currentEventLines.isEmpty,
              Self.eventBraceDepth(currentEventLines) <= 0 else {
            return nil
        }

        return flushCurrentEvent(date: date)
    }

    private mutating func flushCurrentEvent(date: Date) -> AppleMusicLogEvent? {
        guard !currentEventLines.isEmpty else {
            return nil
        }

        let eventDate = currentEventDate ?? date
        let message = currentEventLines.joined(separator: "\n")
        currentEventDate = nil
        currentEventLines.removeAll()

        guard Self.isRelevantMessage(message) else {
            return nil
        }

        return AppleMusicLogEvent(date: eventDate, message: message)
    }

    private static func eventBraceDepth(_ lines: [String]) -> Int {
        var depth = 0
        var isInsideQuotedString = false
        var isEscaped = false

        for character in lines.joined(separator: "\n") {
            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" {
                isInsideQuotedString.toggle()
                continue
            }

            guard !isInsideQuotedString else {
                continue
            }

            switch character {
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
        }

        return depth
    }

    private static func isLogHeader(_ line: String) -> Bool {
        logHeaderPrefix(in: line) != nil
    }

    private static func logHeaderPrefix(in line: String) -> String? {
        guard line.count > 23 else {
            return nil
        }

        let prefix = String(line.prefix(23))
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#
        guard prefix.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        return prefix
    }

    private static func logHeaderDate(_ line: String) -> Date? {
        guard let prefix = logHeaderPrefix(in: line) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: prefix)
    }

    private static func isRelevantMessage(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("item-begin")
            || lowercasedMessage.contains("item tick")
            || lowercasedMessage.contains("asset queue")
            || lowercasedMessage.contains("queue->player synchronization completed")
            || lowercasedMessage.contains("playeritems:")
            || lowercasedMessage.contains("loadedqueueitems:")
            || lowercasedMessage.contains("queue event processed")
            || lowercasedMessage.contains("synchronizequeueitemstoplayer")
            || lowercasedMessage.contains("prior item")
            || lowercasedMessage.contains("audio-format-changed")
            || lowercasedMessage.contains("audio format changed to pbaudioformat.")
            || lowercasedMessage.contains("pbaudioformat.lossless")
            || lowercasedMessage.contains("item-audio-format-metadata")
            || lowercasedMessage.contains("\"active-format\"")
            || lowercasedMessage.contains("grp = \"audio-alac")
    }
}
