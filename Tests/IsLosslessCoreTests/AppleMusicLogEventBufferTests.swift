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
}
