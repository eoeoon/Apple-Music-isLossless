import Foundation

public struct AppleMusicPreloadRecord: Equatable, Sendable {
    public let queueItemID: Int
    public let queueSectionID: Int?
    public let title: String
    public let duration: Double
    public let groupID: String
    public let format: AudioFormat
    public let savedAt: Date

    public init?(
        queueItem: AppleMusicQueueItemBegin,
        formatChange: AppleMusicAudioFormatChange,
        savedAt: Date
    ) {
        guard queueItem.queueItemID == formatChange.queueItemID,
              let groupID = formatChange.groupID,
              let format = formatChange.format else {
            return nil
        }

        self.queueItemID = queueItem.queueItemID
        self.queueSectionID = queueItem.queueSectionID ?? formatChange.queueSectionID
        self.title = queueItem.title
        self.duration = queueItem.duration
        self.groupID = groupID
        self.format = format
        self.savedAt = savedAt
    }
}

public enum AppleMusicPreloadLookupResult: Equatable, Sendable {
    case found(AppleMusicPreloadRecord)
    case fallbackAAC
    case failed
}

public struct AppleMusicPreloadCache: Sendable {
    private var recordsByQueueItemID: [Int: AppleMusicPreloadRecord] = [:]

    public init() {}

    public var isEmpty: Bool {
        recordsByQueueItemID.isEmpty
    }

    public var count: Int {
        recordsByQueueItemID.count
    }

    public var records: [AppleMusicPreloadRecord] {
        recordsByQueueItemID.values.sorted { $0.savedAt > $1.savedAt }
    }

    @discardableResult
    public mutating func store(_ record: AppleMusicPreloadRecord) -> AppleMusicPreloadRecord? {
        let existing = recordsByQueueItemID[record.queueItemID]
        recordsByQueueItemID[record.queueItemID] = record
        return existing
    }

    public func lookup(title: String?, duration: Double?) -> AppleMusicPreloadLookupResult {
        guard !recordsByQueueItemID.isEmpty else {
            return .failed
        }

        guard let title,
              let duration else {
            return .fallbackAAC
        }

        guard let record = records.first(where: { $0.matches(title: title, duration: duration) }) else {
            return .fallbackAAC
        }

        return .found(record)
    }
}

public struct AppleMusicPreloadAssembler: Sendable {
    private var pendingQueueItems: [Int: PendingQueueItem] = [:]
    private var pendingFormatChanges: [Int: PendingFormatChange] = [:]

    public init() {}

    public mutating func ingest(
        message: String,
        date: Date,
        parser: AppleMusicLogParser
    ) -> [AppleMusicPreloadRecord] {
        var completedRecords: [AppleMusicPreloadRecord] = []

        if let queueItem = parser.parseQueueItemBegin(message),
           let record = ingest(queueItem: queueItem, savedAt: date) {
            completedRecords.append(record)
        }

        if let formatChange = parser.parseAudioFormatChanged(message),
           let record = ingest(formatChange: formatChange, savedAt: date),
           !completedRecords.contains(record) {
            completedRecords.append(record)
        }

        return completedRecords
    }

    public mutating func ingest(
        queueItem: AppleMusicQueueItemBegin,
        savedAt: Date
    ) -> AppleMusicPreloadRecord? {
        pendingQueueItems[queueItem.queueItemID] = PendingQueueItem(item: queueItem, savedAt: savedAt)
        return completeRecordIfPossible(queueItemID: queueItem.queueItemID)
    }

    public mutating func ingest(
        formatChange: AppleMusicAudioFormatChange,
        savedAt: Date
    ) -> AppleMusicPreloadRecord? {
        guard formatChange.groupID != nil,
              formatChange.format != nil else {
            return nil
        }

        pendingFormatChanges[formatChange.queueItemID] = PendingFormatChange(change: formatChange, savedAt: savedAt)
        return completeRecordIfPossible(queueItemID: formatChange.queueItemID)
    }

    private func completeRecordIfPossible(queueItemID: Int) -> AppleMusicPreloadRecord? {
        guard let queueItem = pendingQueueItems[queueItemID],
              let formatChange = pendingFormatChanges[queueItemID] else {
            return nil
        }

        return AppleMusicPreloadRecord(
            queueItem: queueItem.item,
            formatChange: formatChange.change,
            savedAt: max(queueItem.savedAt, formatChange.savedAt)
        )
    }

    private struct PendingQueueItem: Sendable {
        let item: AppleMusicQueueItemBegin
        let savedAt: Date
    }

    private struct PendingFormatChange: Sendable {
        let change: AppleMusicAudioFormatChange
        let savedAt: Date
    }
}

private extension AppleMusicPreloadRecord {
    func matches(title: String, duration: Double) -> Bool {
        self.title.precomposedStringWithCanonicalMapping == title.precomposedStringWithCanonicalMapping
            && integerSeconds(self.duration) == integerSeconds(duration)
    }

    func integerSeconds(_ value: Double) -> Int {
        Int(value)
    }
}
