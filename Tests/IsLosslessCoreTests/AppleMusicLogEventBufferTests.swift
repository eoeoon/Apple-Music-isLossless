import Foundation
import Testing
@testable import IsLosslessCore

@Suite("Apple Music log event buffering")
struct AppleMusicLogEventBufferTests {
    private let parser = AppleMusicLogParser()

    @Test func flushesAudioFormatEventEndingWithSemicolonBrace() {
        var buffer = AppleMusicLogEventBuffer()
        let date = Date(timeIntervalSince1970: 100)
        let events = buffer.ingest(
            """
            2026-06-19 10:34:40.913 Db Music[1937:15653] [com.apple.amp.mediaplaybackcore:PlaybackEventStream_Oversize] emitEventType:audio-format-changed payload:{
                "item-audio-format-metadata" = {
                    "active-format" = {
                        bd = 16;
                        grp = "audio-alac-stereo-44100-16";
                        sr = 44100;
                    };
                };
                "queue-item-id" = 4039;
                "queue-section-id" = 3975;
            };

            """,
            date: date
        )

        #expect(events.count == 1)
        let dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: events.first?.date ?? date
        )
        #expect(dateComponents.year == 2026)
        #expect(dateComponents.month == 6)
        #expect(dateComponents.day == 19)
        #expect(dateComponents.hour == 10)
        #expect(dateComponents.minute == 34)
        #expect(dateComponents.second == 40)
        #expect(parser.parseAudioFormatChanged(events.first?.message ?? "")?.queueItemID == 4039)
        #expect(parser.parseAudioFormatChanged(events.first?.message ?? "")?.groupID == "audio-alac-stereo-44100-16")
    }

    @Test func flushesBurstEventsFromSingleChunkIntoCompletedPreloadRecord() {
        var buffer = AppleMusicLogEventBuffer()
        let date = Date(timeIntervalSince1970: 200)
        let events = buffer.ingest(
            """
            2026-06-19 10:34:39.913 Db Music[1937:15653] [com.apple.amp.mediaplaybackcore:Engagement_Oversize] Event: {
                "event-type" = "item-begin";
                payload = {
                    "item-metadata" = {
                        "item-duration" = "154.3";
                        "item-title" = "3am";
                    };
                    "queue-item-id" = 4039;
                    "queue-section-id" = 3975;
                };
            };
            2026-06-19 10:34:40.913 Db Music[1937:15653] [com.apple.amp.mediaplaybackcore:PlaybackEventStream_Oversize] emitEventType:audio-format-changed payload:{
                "item-audio-format-metadata" = {
                    "active-format" = {
                        bd = 16;
                        grp = "audio-alac-stereo-44100-16";
                        sr = 44100;
                    };
                };
                "queue-item-id" = 4039;
                "queue-section-id" = 3975;
            };

            """,
            date: date
        )

        var assembler = AppleMusicPreloadAssembler()
        let records = events.flatMap { event in
            assembler.ingest(message: event.message, date: event.date, parser: parser)
        }

        #expect(events.count == 2)
        #expect(records.count == 1)
        #expect(records.first?.queueItemID == 4039)
        #expect(records.first?.title == "3am")
        #expect(records.first?.groupID == "audio-alac-stereo-44100-16")
    }

    @Test func quotedBracesDoNotHoldRelevantEventOpen() {
        var buffer = AppleMusicLogEventBuffer()
        let events = buffer.ingest(
            """
            2026-06-19 10:34:39.913 Db Music[1937:15653] [com.apple.amp.mediaplaybackcore:Engagement_Oversize] Event: {
                "event-type" = "item-begin";
                payload = {
                    "item-metadata" = {
                        "item-duration" = "154.3";
                        "item-title" = "Song {Live";
                    };
                    "queue-item-id" = 4040;
                    "queue-section-id" = 3975;
                };
            };

            """
        )

        #expect(events.count == 1)
        #expect(parser.parseQueueItemBegin(events.first?.message ?? "")?.queueItemID == 4040)
        #expect(parser.parseQueueItemBegin(events.first?.message ?? "")?.title == "Song {Live")
    }

    @Test func flushesPlaybackLosslessFormatEvent() {
        var buffer = AppleMusicLogEventBuffer()
        let fallbackDate = Date(timeIntervalSince1970: 100)
        let events = buffer.ingest(
            """
            2026-06-19 12:35:01.123 Db Music[1937:15653] [com.apple.amp.mediaplaybackcore:Playback] Audio format changed to PBAudioFormat.lossless.

            """,
            date: fallbackDate
        )

        #expect(events.count == 1)
        #expect(parser.parsePlaybackFormat(events.first?.message ?? "")?.codec == "ALAC")
        let dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: events.first?.date ?? fallbackDate
        )
        #expect(dateComponents.year == 2026)
        #expect(dateComponents.month == 6)
        #expect(dateComponents.day == 19)
        #expect(dateComponents.hour == 12)
        #expect(dateComponents.minute == 35)
        #expect(dateComponents.second == 1)
    }

    @Test func flushesPlaybackEventsQueueSignals() {
        var buffer = AppleMusicLogEventBuffer()
        let events = buffer.ingest(
            """
            2026-06-20 19:46:14.128 Df Music[80355:1d3532] [com.apple.amp.mediaplaybackcore:PlaybackEvents] ITEM TICK                  8502 8582                   ║ 2:38.48 ━━━━━━━━━━━━━━━━━━━━━━━━━●━━━ -0:20.51
            2026-06-20 19:43:34.989 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] ASSET QUEUE                  Suspending asset task at 'loadItem' for 8502::8584 [prior item 8502::8582 not finished] [IT-8501]
            2026-06-20 20:59:49.446 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] QUEUE EVENT PROCESSED   〔PlayingState〕- CoordinatorEvent.synchronizeQueueItemsToPlayer - items:[<ITMPAVItem: 0xbc9616300> (8881+9094::9096) romeo n juliet (feat. 유라), <ITMPAVItem: 0xbc8fda300> (8881+9103::9105) I Really Want to Stay At Your House] hasLoadedAllItems:false
            2026-06-20 21:16:21.774 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] Queue->Player synchronization completed - playerItems:[<AVPlayerItem: 0xbcc5a3cc0> I/HBN [8881::8929] <ITMPAVItem: 0xbca39c700> (8881::8929) 가질 수 없는 너], <AVPlayerItem: 0xbcc494d70> I/IBB [8881+9139::9141] <ITMPAVItem: 0xbcab4dc00> (8881+9139::9141) 보라빛 밤]]
            2026-06-20 21:16:22.349 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] ASSET QUEUE State: AssetQueueState(currentQueueItem: Optional(<ITMPAVItem: 0xbca39c700> (8881::8929) 가질 수 없는 너), loadedQueueItems: [<ITMPAVItem: 0xbca39c700> (8881::8929) 가질 수 없는 너, <ITMPAVItem: 0xbcbf1c380> (8881+9147::9149) Into the I-Land], unskippableError: nil)

            """
        )

        #expect(events.count == 5)
        #expect(parser.parsePlaybackItemTick(events[0].message)?.queueItemID == 8582)
        #expect(parser.parseAssetQueueLink(events[1].message)?.nextQueueItemID == 8584)
        #expect(parser.parseQueueItemsSnapshotLinks(events[2].message).first?.priorQueueItemID == 9096)
        #expect(parser.parseQueueSnapshot(events[3].message)?.source == .playerQueue)
        #expect(parser.parseQueueSnapshot(events[4].message)?.source == .assetQueueState)
    }
}
