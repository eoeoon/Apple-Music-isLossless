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
        #expect(record?.groupID == "audio-alac-stereo-44100-16")
        #expect(record?.format.codec == "ALAC")
        #expect(record?.savedAt == formatDate)
    }

    @Test func assemblesCompletedRecordWhenFormatArrivesBeforeItem() {
        var assembler = AppleMusicPreloadAssembler()
        let itemDate = Date(timeIntervalSince1970: 120)
        let formatDate = Date(timeIntervalSince1970: 110)

        #expect(assembler.ingest(formatChange: formatChange(id: 4039), savedAt: formatDate) == nil)
        let record = assembler.ingest(queueItem: queueItem(id: 4039), savedAt: itemDate)

        #expect(record?.queueItemID == 4039)
        #expect(record?.groupID == "audio-alac-stereo-44100-16")
        #expect(record?.savedAt == itemDate)
    }

    @Test func doesNotMixFormatFromDifferentQueueItem() {
        var assembler = AppleMusicPreloadAssembler()

        #expect(assembler.ingest(queueItem: queueItem(id: 3854), savedAt: Date()) == nil)
        #expect(assembler.ingest(formatChange: formatChange(id: 3856), savedAt: Date()) == nil)
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

    private func record(
        id: Int,
        title: String? = nil,
        savedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> AppleMusicPreloadRecord? {
        AppleMusicPreloadRecord(
            queueItem: queueItem(id: id, title: title),
            formatChange: formatChange(id: id),
            savedAt: savedAt
        )
    }

    private func queueItem(id: Int, title: String? = nil) -> AppleMusicQueueItemBegin {
        AppleMusicQueueItemBegin(
            title: title ?? "Song \(id)",
            duration: 250.9,
            queueItemID: id,
            queueSectionID: 3975
        )
    }

    private func formatChange(id: Int) -> AppleMusicAudioFormatChange {
        AppleMusicAudioFormatChange(
            queueItemID: id,
            queueSectionID: 3975,
            groupID: "audio-alac-stereo-44100-16",
            format: AudioFormat(codec: "ALAC", bitDepth: 16, sampleRate: 44_100)
        )
    }
}
