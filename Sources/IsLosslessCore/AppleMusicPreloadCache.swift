import Foundation

public struct AppleMusicPreloadRecord: Equatable, Sendable {
    public let queueItemID: Int
    public let queueSectionID: Int?
    public let title: String?
    public let duration: Double?
    public let groupID: String
    public let format: AudioFormat
    public let savedAt: Date

    public init?(
        formatChange: AppleMusicAudioFormatChange,
        savedAt: Date
    ) {
        guard let groupID = formatChange.groupID,
              let format = formatChange.format else {
            return nil
        }

        self.queueItemID = formatChange.queueItemID
        self.queueSectionID = formatChange.queueSectionID
        self.title = nil
        self.duration = nil
        self.groupID = groupID
        self.format = format
        self.savedAt = savedAt
    }

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

    public func enrichingMetadata(from queueItem: AppleMusicQueueItemBegin, savedAt: Date) -> AppleMusicPreloadRecord? {
        guard queueItem.queueItemID == queueItemID else {
            return nil
        }

        return AppleMusicPreloadRecord(
            queueItemID: queueItemID,
            queueSectionID: queueItem.queueSectionID ?? queueSectionID,
            title: queueItem.title,
            duration: queueItem.duration,
            groupID: groupID,
            format: format,
            savedAt: max(self.savedAt, savedAt)
        )
    }

    public var hasMetadata: Bool {
        title != nil && duration != nil
    }

    private init(
        queueItemID: Int,
        queueSectionID: Int?,
        title: String?,
        duration: Double?,
        groupID: String,
        format: AudioFormat,
        savedAt: Date
    ) {
        self.queueItemID = queueItemID
        self.queueSectionID = queueSectionID
        self.title = title
        self.duration = duration
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

public enum AppleMusicPreloadStoreResult: Equatable, Sendable {
    case inserted(AppleMusicPreloadRecord)
    case updated(previous: AppleMusicPreloadRecord, current: AppleMusicPreloadRecord)
    case unchanged(AppleMusicPreloadRecord)
}

public struct AppleMusicQueueReorder: Equatable, Sendable {
    public let source: AppleMusicQueueSnapshotSource
    public let queueSectionID: Int
    public let currentQueueItemID: Int
    public let oldNextQueueItemID: Int
    public let newNextQueueItemID: Int

    public init(
        source: AppleMusicQueueSnapshotSource,
        queueSectionID: Int,
        currentQueueItemID: Int,
        oldNextQueueItemID: Int,
        newNextQueueItemID: Int
    ) {
        self.source = source
        self.queueSectionID = queueSectionID
        self.currentQueueItemID = currentQueueItemID
        self.oldNextQueueItemID = oldNextQueueItemID
        self.newNextQueueItemID = newNextQueueItemID
    }
}

public struct AppleMusicQueueSnapshotStoreResult: Equatable, Sendable {
    public let snapshot: AppleMusicQueueSnapshot
    public let changedLinks: [AppleMusicAssetQueueLink]
    public let reorders: [AppleMusicQueueReorder]

    public init(
        snapshot: AppleMusicQueueSnapshot,
        changedLinks: [AppleMusicAssetQueueLink],
        reorders: [AppleMusicQueueReorder]
    ) {
        self.snapshot = snapshot
        self.changedLinks = changedLinks
        self.reorders = reorders
    }
}

public struct AppleMusicPreloadCache: Sendable {
    private var recordsByQueueItemID: [Int: AppleMusicPreloadRecord] = [:]
    private var nextQueueItemIDsByQueueItemID: [Int: Int] = [:]

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

    public func record(queueItemID: Int) -> AppleMusicPreloadRecord? {
        recordsByQueueItemID[queueItemID]
    }

    @discardableResult
    public mutating func store(_ record: AppleMusicPreloadRecord) -> AppleMusicPreloadStoreResult {
        let existing = recordsByQueueItemID[record.queueItemID]
        let storedRecord = record.preservingMetadata(from: existing)

        guard let existing else {
            recordsByQueueItemID[record.queueItemID] = storedRecord
            return .inserted(storedRecord)
        }

        guard !existing.hasSameCachePayload(as: storedRecord) else {
            return .unchanged(existing)
        }

        recordsByQueueItemID[record.queueItemID] = storedRecord
        return .updated(previous: existing, current: storedRecord)
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

    @discardableResult
    public mutating func rememberNext(currentQueueItemID: Int, nextQueueItemID: Int) -> Bool {
        let previous = nextQueueItemIDsByQueueItemID[currentQueueItemID]
        guard previous != nextQueueItemID else {
            return false
        }

        nextQueueItemIDsByQueueItemID[currentQueueItemID] = nextQueueItemID
        return true
    }

    @discardableResult
    public mutating func rememberNext(_ link: AppleMusicAssetQueueLink) -> Bool {
        rememberNext(currentQueueItemID: link.priorQueueItemID, nextQueueItemID: link.nextQueueItemID)
    }

    @discardableResult
    public mutating func rememberQueueSnapshot(_ snapshot: AppleMusicQueueSnapshot) -> AppleMusicQueueSnapshotStoreResult {
        var changedLinks: [AppleMusicAssetQueueLink] = []
        var reorders: [AppleMusicQueueReorder] = []

        for link in snapshot.links {
            let previous = nextQueueItemIDsByQueueItemID[link.priorQueueItemID]
            guard previous != link.nextQueueItemID else {
                continue
            }

            if let previous {
                reorders.append(
                    AppleMusicQueueReorder(
                        source: snapshot.source,
                        queueSectionID: link.queueSectionID,
                        currentQueueItemID: link.priorQueueItemID,
                        oldNextQueueItemID: previous,
                        newNextQueueItemID: link.nextQueueItemID
                    )
                )
            }

            nextQueueItemIDsByQueueItemID[link.priorQueueItemID] = link.nextQueueItemID
            changedLinks.append(link)
        }

        return AppleMusicQueueSnapshotStoreResult(
            snapshot: snapshot,
            changedLinks: changedLinks,
            reorders: reorders
        )
    }

    public func nextRecord(after record: AppleMusicPreloadRecord) -> AppleMusicPreloadRecord? {
        nextRecord(afterQueueItemID: record.queueItemID, queueSectionID: record.queueSectionID)
    }

    public func nextRecord(afterQueueItemID queueItemID: Int, queueSectionID: Int?) -> AppleMusicPreloadRecord? {
        if let explicitNextQueueItemID = nextQueueItemIDsByQueueItemID[queueItemID] {
            return recordsByQueueItemID[explicitNextQueueItemID]
        }

        let laterRecords = recordsByQueueItemID.values.filter {
            $0.queueItemID > queueItemID
        }

        if let queueSectionID {
            return laterRecords
                .filter { $0.queueSectionID == queueSectionID }
                .min { $0.queueItemID < $1.queueItemID }
        }

        return laterRecords.min { $0.queueItemID < $1.queueItemID }
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

        for formatChange in parser.parseAudioFormatChanges(message) {
            if let record = ingest(formatChange: formatChange, savedAt: date),
               !completedRecords.contains(record) {
                completedRecords.append(record)
            }
        }

        return completedRecords
    }

    public mutating func ingest(
        queueItem: AppleMusicQueueItemBegin,
        savedAt: Date
    ) -> AppleMusicPreloadRecord? {
        pendingQueueItems[queueItem.queueItemID] = PendingQueueItem(item: queueItem, savedAt: savedAt)
        return pendingFormatChanges[queueItem.queueItemID]?.record.enrichingMetadata(
            from: queueItem,
            savedAt: savedAt
        )
    }

    public mutating func ingest(
        formatChange: AppleMusicAudioFormatChange,
        savedAt: Date
    ) -> AppleMusicPreloadRecord? {
        guard formatChange.groupID != nil,
              formatChange.format != nil,
              let record = AppleMusicPreloadRecord(formatChange: formatChange, savedAt: savedAt) else {
            return nil
        }

        pendingFormatChanges[formatChange.queueItemID] = PendingFormatChange(record: record)
        if let queueItem = pendingQueueItems[formatChange.queueItemID] {
            return record.enrichingMetadata(from: queueItem.item, savedAt: queueItem.savedAt)
        }
        return record
    }

    private struct PendingQueueItem: Sendable {
        let item: AppleMusicQueueItemBegin
        let savedAt: Date
    }

    private struct PendingFormatChange: Sendable {
        let record: AppleMusicPreloadRecord
    }
}

private extension AppleMusicPreloadRecord {
    func matches(title: String, duration: Double) -> Bool {
        guard let recordTitle = self.title,
              let recordDuration = self.duration else {
            return false
        }

        return recordTitle.precomposedStringWithCanonicalMapping == title.precomposedStringWithCanonicalMapping
            && integerSeconds(recordDuration) == integerSeconds(duration)
    }

    func integerSeconds(_ value: Double) -> Int {
        Int(value)
    }

    func preservingMetadata(from existing: AppleMusicPreloadRecord?) -> AppleMusicPreloadRecord {
        guard let existing,
              title == nil,
              duration == nil,
              let existingTitle = existing.title,
              let existingDuration = existing.duration else {
            return self
        }

        return AppleMusicPreloadRecord(
            queueItemID: queueItemID,
            queueSectionID: queueSectionID ?? existing.queueSectionID,
            title: existingTitle,
            duration: existingDuration,
            groupID: groupID,
            format: format,
            savedAt: max(savedAt, existing.savedAt)
        )
    }

    func hasSameCachePayload(as other: AppleMusicPreloadRecord) -> Bool {
        queueItemID == other.queueItemID
            && queueSectionID == other.queueSectionID
            && title == other.title
            && duration == other.duration
            && groupID == other.groupID
            && format == other.format
    }
}
