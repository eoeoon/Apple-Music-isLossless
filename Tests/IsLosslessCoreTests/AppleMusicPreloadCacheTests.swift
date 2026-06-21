import Foundation
import Testing
@testable import IsLosslessCore

@Suite("Apple Music preload cache")
struct AppleMusicPreloadCacheTests {
    @Test func assemblesCompletedRecordWhenItemArrivesBeforeFormat() {
        var assembler = AppleMusicPreloadAssembler()
        let itemDate = Date(timeIntervalSince1970: 100)
        let formatDate = Date(timeIntervalSince1970: 110)

        #expect(assembler.ingest(queueItem: queueItem(id: 4039), savedAt: itemDate) == nil)
        let record = assembler.ingest(formatChange: formatChange(id: 4039), savedAt: formatDate)

        #expect(record?.queueItemID == 4039)
        #expect(record?.title == "Song 4039")
        #expect(record?.duration == 250.9)
        #expect(record?.groupID == "audio-alac-stereo-44100-16")
        #expect(record?.format.codec == "ALAC")
        #expect(record?.savedAt == formatDate)
    }

    @Test func returnsFormatOnlyRecordWhenFormatArrivesBeforeItem() {
        var assembler = AppleMusicPreloadAssembler()
        let formatDate = Date(timeIntervalSince1970: 110)

        let record = assembler.ingest(formatChange: formatChange(id: 4039), savedAt: formatDate)

        #expect(record?.queueItemID == 4039)
        #expect(record?.title == nil)
        #expect(record?.duration == nil)
        #expect(record?.groupID == "audio-alac-stereo-44100-16")
        #expect(record?.savedAt == formatDate)
    }

    @Test func ingestsMultipleScopedFormatPayloadsFromOneMessage() {
        var assembler = AppleMusicPreloadAssembler()
        let parser = AppleMusicLogParser()
        let message = """
        emitEventType:audio-format-changed payload={
            "item-audio-format-metadata" = {
                "active-format" = {
                    bd = 24;
                    grp = "audio-alac-stereo-48000-24";
                    sr = 48000;
                };
            };
            "queue-item-id" = 3698;
            "queue-section-id" = 3608;
        }
        emitEventType:audio-format-changed payload={
            "item-audio-format-metadata" = {
                "active-format" = {
                    bd = 24;
                    grp = "audio-alac-stereo-96000-24";
                    sr = 96000;
                };
            };
            "queue-item-id" = 3702;
            "queue-section-id" = 3608;
        }
        """

        let records = assembler.ingest(
            message: message,
            date: Date(timeIntervalSince1970: 110),
            parser: parser
        )

        #expect(records.map(\.queueItemID) == [3698, 3702])
        #expect(records.map(\.groupID) == [
            "audio-alac-stereo-48000-24",
            "audio-alac-stereo-96000-24"
        ])
    }

    @Test func enrichesFormatOnlyRecordWhenItemArrivesLater() {
        var assembler = AppleMusicPreloadAssembler()
        let itemDate = Date(timeIntervalSince1970: 120)
        let formatDate = Date(timeIntervalSince1970: 110)

        _ = assembler.ingest(formatChange: formatChange(id: 4039), savedAt: formatDate)
        let record = assembler.ingest(queueItem: queueItem(id: 4039), savedAt: itemDate)

        #expect(record?.queueItemID == 4039)
        #expect(record?.title == "Song 4039")
        #expect(record?.duration == 250.9)
        #expect(record?.groupID == "audio-alac-stereo-44100-16")
        #expect(record?.savedAt == itemDate)
    }

    @Test func doesNotMixFormatFromDifferentQueueItem() {
        var assembler = AppleMusicPreloadAssembler()

        #expect(assembler.ingest(queueItem: queueItem(id: 3854), savedAt: Date()) == nil)
        let record = assembler.ingest(formatChange: formatChange(id: 3856), savedAt: Date())

        #expect(record?.queueItemID == 3856)
        #expect(record?.title == nil)
        #expect(record?.duration == nil)
    }

    @Test func completedRecordDoesNotExpireByTime() throws {
        var cache = AppleMusicPreloadCache()
        let oldRecord = try #require(record(id: 4039, savedAt: Date(timeIntervalSince1970: 0)))

        cache.store(oldRecord)

        #expect(cache.lookup(title: "Song 4039", duration: 250.9) == .found(oldRecord))
    }

    @Test func emptyCacheLookupFails() {
        let cache = AppleMusicPreloadCache()

        #expect(cache.lookup(title: "Song 4039", duration: 250.9) == .failed)
    }

    @Test func nonEmptyCacheWithoutMatchFallsBackToAAC() throws {
        var cache = AppleMusicPreloadCache()
        cache.store(try #require(record(id: 4039)))

        #expect(cache.lookup(title: "Different Song", duration: 111) == .fallbackAAC)
    }

    @Test func formatOnlyRecordIsNotUsedForCurrentTrackLookup() throws {
        var cache = AppleMusicPreloadCache()
        let record = try #require(formatOnlyRecord(id: 4039))

        cache.store(record)

        #expect(cache.count == 1)
        #expect(cache.record(queueItemID: 4039) == record)
        #expect(cache.lookup(title: "Song 4039", duration: 250.9) == .fallbackAAC)
    }

    @Test func duplicateQueueItemOverwritesRecord() throws {
        var cache = AppleMusicPreloadCache()
        let first = try #require(record(id: 4039, title: "Old Song"))
        let replacement = try #require(record(id: 4039, title: "New Song"))

        cache.store(first)
        cache.store(replacement)

        #expect(cache.count == 1)
        #expect(cache.lookup(title: "Old Song", duration: 250.9) == .fallbackAAC)
        #expect(cache.lookup(title: "New Song", duration: 250.9) == .found(replacement))
    }

    @Test func duplicateFormatOnlyRecordWithDifferentSavedAtIsUnchanged() throws {
        var cache = AppleMusicPreloadCache()
        let first = try #require(formatOnlyRecord(id: 4039, savedAt: Date(timeIntervalSince1970: 100)))
        let duplicate = try #require(formatOnlyRecord(id: 4039, savedAt: Date(timeIntervalSince1970: 200)))

        #expect(cache.store(first) == .inserted(first))
        #expect(cache.store(duplicate) == .unchanged(first))
        #expect(cache.records == [first])
    }

    @Test func duplicateFormatOnlyRecordDoesNotOverwriteMetadata() throws {
        var cache = AppleMusicPreloadCache()
        let completed = try #require(record(id: 4039, savedAt: Date(timeIntervalSince1970: 100)))
        let duplicateFormat = try #require(formatOnlyRecord(id: 4039, savedAt: Date(timeIntervalSince1970: 200)))

        #expect(cache.store(completed) == .inserted(completed))
        #expect(cache.store(duplicateFormat) == .unchanged(completed))
        #expect(cache.lookup(title: "Song 4039", duration: 250.9) == .found(completed))
    }

    @Test func nextRecordChoosesNextQueueItemInSameSection() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3779, sectionID: 42))
        let sameSectionNext = try #require(record(id: 3995, sectionID: 42))
        let differentSectionEarlier = try #require(record(id: 3900, sectionID: 99))

        cache.store(current)
        cache.store(sameSectionNext)
        cache.store(differentSectionEarlier)

        #expect(cache.nextRecord(after: current) == sameSectionNext)
    }

    @Test func nextRecordReturnsNilWhenNoLaterRecordExists() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3995, sectionID: 42))
        let previous = try #require(record(id: 3779, sectionID: 42))

        cache.store(current)
        cache.store(previous)

        #expect(cache.nextRecord(after: current) == nil)
    }

    @Test func nextRecordIgnoresDifferentSectionWhenCurrentHasSection() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3779, sectionID: 42))
        let differentSectionNext = try #require(record(id: 3995, sectionID: 99))

        cache.store(current)
        cache.store(differentSectionNext)

        #expect(cache.nextRecord(after: current) == nil)
    }

    @Test func nextRecordUsesQueueOrderInsteadOfSavedOrder() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3779, sectionID: nil, savedAt: Date(timeIntervalSince1970: 300)))
        let actualNext = try #require(record(id: 3995, sectionID: nil, savedAt: Date(timeIntervalSince1970: 100)))
        let laterQueueItemSavedLater = try #require(record(id: 4200, sectionID: nil, savedAt: Date(timeIntervalSince1970: 400)))

        cache.store(laterQueueItemSavedLater)
        cache.store(current)
        cache.store(actualNext)

        #expect(cache.nextRecord(after: current) == actualNext)
    }

    @Test func nextRecordCanUseFormatOnlyRecord() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3779, sectionID: 42))
        let next = try #require(formatOnlyRecord(id: 3995, sectionID: 42))

        cache.store(current)
        cache.store(next)

        #expect(cache.nextRecord(after: current) == next)
    }

    @Test func nextRecordCanUsePlaybackTickSectionOverride() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3779, sectionID: 99))
        let next = try #require(formatOnlyRecord(id: 3995, sectionID: 42))

        cache.store(current)
        cache.store(next)

        #expect(cache.nextRecord(after: current) == nil)
        #expect(cache.nextRecord(afterQueueItemID: 3779, queueSectionID: 42) == next)
    }

    @Test func nextRecordUsesExplicitQueueLinkBeforeQueueOrder() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3779, sectionID: 42))
        let queueOrderNext = try #require(record(id: 3995, sectionID: 42))
        let linkedNext = try #require(record(id: 4200, sectionID: 42))

        cache.store(current)
        cache.store(queueOrderNext)
        cache.store(linkedNext)
        cache.rememberNext(currentQueueItemID: 3779, nextQueueItemID: 4200)

        #expect(cache.nextRecord(after: current) == linkedNext)
    }

    @Test func nextRecordWaitsWhenExplicitLinkTargetFormatIsMissing() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 3779, sectionID: 42))
        let queueOrderNext = try #require(record(id: 3995, sectionID: 42))

        cache.store(current)
        cache.store(queueOrderNext)
        cache.rememberNext(currentQueueItemID: 3779, nextQueueItemID: 4200)

        #expect(cache.nextRecord(after: current) == nil)

        let linkedNext = try #require(formatOnlyRecord(id: 4200, sectionID: 42))
        cache.store(linkedNext)

        #expect(cache.nextRecord(after: current) == linkedNext)
    }

    @Test func queueSnapshotOverwritesExistingExplicitNext() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 8929, sectionID: 8881))
        let oldNext = try #require(formatOnlyRecord(id: 8931, sectionID: 8881))
        let newNext = try #require(formatOnlyRecord(id: 9149, sectionID: 8881))
        let following = try #require(formatOnlyRecord(id: 9141, sectionID: 8881))

        cache.store(current)
        cache.store(oldNext)
        cache.store(newNext)
        cache.store(following)
        cache.rememberNext(currentQueueItemID: 8929, nextQueueItemID: 8931)

        let result = cache.rememberQueueSnapshot(
            AppleMusicQueueSnapshot(
                source: .assetQueueState,
                items: [
                    AppleMusicQueueItemReference(queueSectionID: 8881, queueItemID: 8929),
                    AppleMusicQueueItemReference(queueSectionID: 8881, queueItemID: 9149),
                    AppleMusicQueueItemReference(queueSectionID: 8881, queueItemID: 9141)
                ]
            )
        )

        #expect(cache.nextRecord(after: current) == newNext)
        #expect(result.changedLinks.map(\.priorQueueItemID) == [8929, 9149])
        #expect(result.changedLinks.map(\.nextQueueItemID) == [9149, 9141])
        #expect(result.reorders == [
            AppleMusicQueueReorder(
                source: .assetQueueState,
                queueSectionID: 8881,
                currentQueueItemID: 8929,
                oldNextQueueItemID: 8931,
                newNextQueueItemID: 9149
            )
        ])
    }

    @Test func queueSnapshotNewNextWithoutFormatBlocksQueueOrderFallback() throws {
        var cache = AppleMusicPreloadCache()
        let current = try #require(record(id: 8929, sectionID: 8881))
        let oldNext = try #require(formatOnlyRecord(id: 8931, sectionID: 8881))

        cache.store(current)
        cache.store(oldNext)
        cache.rememberNext(currentQueueItemID: 8929, nextQueueItemID: 8931)

        _ = cache.rememberQueueSnapshot(
            AppleMusicQueueSnapshot(
                source: .playerQueue,
                items: [
                    AppleMusicQueueItemReference(queueSectionID: 8881, queueItemID: 8929),
                    AppleMusicQueueItemReference(queueSectionID: 8881, queueItemID: 9141)
                ]
            )
        )

        #expect(cache.nextRecord(after: current) == nil)

        let newNext = try #require(formatOnlyRecord(id: 9141, sectionID: 8881))
        cache.store(newNext)

        #expect(cache.nextRecord(after: current) == newNext)
    }

    private func record(
        id: Int,
        title: String? = nil,
        sectionID: Int? = 3975,
        savedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> AppleMusicPreloadRecord? {
        AppleMusicPreloadRecord(
            queueItem: queueItem(id: id, title: title, sectionID: sectionID),
            formatChange: formatChange(id: id, sectionID: sectionID),
            savedAt: savedAt
        )
    }

    private func formatOnlyRecord(
        id: Int,
        sectionID: Int? = 3975,
        savedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> AppleMusicPreloadRecord? {
        AppleMusicPreloadRecord(
            formatChange: formatChange(id: id, sectionID: sectionID),
            savedAt: savedAt
        )
    }

    private func queueItem(id: Int, title: String? = nil, sectionID: Int? = 3975) -> AppleMusicQueueItemBegin {
        AppleMusicQueueItemBegin(
            title: title ?? "Song \(id)",
            duration: 250.9,
            queueItemID: id,
            queueSectionID: sectionID
        )
    }

    private func formatChange(id: Int, sectionID: Int? = 3975) -> AppleMusicAudioFormatChange {
        AppleMusicAudioFormatChange(
            queueItemID: id,
            queueSectionID: sectionID,
            groupID: "audio-alac-stereo-44100-16",
            format: AudioFormat(codec: "ALAC", bitDepth: 16, sampleRate: 44_100)
        )
    }
}
