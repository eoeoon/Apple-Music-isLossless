import Testing
@testable import IsLosslessCore

@Suite("Apple Music log parsing")
struct AppleMusicLogParserTests {
    private let parser = AppleMusicLogParser()

    @Test func parsesCoreAudioStyleLosslessMessage() {
        let message = "ACAppleLosslessDecoder.cpp Input format: 96000 Hz, 24-bit source"
        let format = parser.parse(message)

        #expect(format?.codec == "ALAC")
        #expect(format?.bitDepth == 24)
        #expect(format?.sampleRate == 96_000)
    }

    @Test func ignoresAudioCapabilityFields() {
        let message = "audioCapabilities: asbdSampleRate = 44100, sdBitDepth = 16"
        let format = parser.parse(message)

        #expect(format == nil)
    }

    @Test func parsesAACSourceInputFormat() {
        let message = "AACDecoder.cpp Input format: 44100 Hz"
        let format = parser.parse(message)

        #expect(format?.codec == "AAC")
        #expect(format?.bitDepth == nil)
        #expect(format?.sampleRate == 44_100)
    }

    @Test func parsesSourceFormatFields() {
        let message = "source format: 44100 Hz, 16-bit"
        let format = parser.parse(message)

        #expect(format?.bitDepth == 16)
        #expect(format?.sampleRate == 44_100)
    }

    @Test func parsesCoreMediaLosslessPlaybackReport() {
        let message = "[AudioFormat qlac is  decodable] [Rendition Lossless] [SampleRate 44100] [BitDepth 16]"
        let format = parser.parse(message)

        #expect(format?.codec == "ALAC")
        #expect(format?.bitDepth == 16)
        #expect(format?.sampleRate == 44_100)
    }

    @Test func parsesHLSAlacAlternate() {
        let message = "<FigAlternate( 3)> [AudioOnly] [AudioGroup audio-alac-stereo-48000-24] [alac]"
        let format = parser.parse(message)

        #expect(format?.codec == "ALAC")
        #expect(format?.bitDepth == 24)
        #expect(format?.sampleRate == 48_000)
    }

    @Test func parsesActiveFormatReport() {
        let message = "activeFormat: tier: Lossless; groupID: audio-alac-stereo-48000-24; bitDepth: 24-bit; sampleRate: 48khz; codec: alac"
        let format = parser.parse(message)

        #expect(format?.codec == "ALAC")
        #expect(format?.bitDepth == 24)
        #expect(format?.sampleRate == 48_000)
    }

    @Test func parsesCurrentPlaybackLosslessState() {
        let message = "Audio format changed to PBAudioFormat.lossless."
        let format = parser.parsePlaybackFormat(message)

        #expect(format?.codec == "ALAC")
    }

    @Test func parsesCurrentPlaybackOtherState() {
        let message = "Audio format changed to PBAudioFormat.other."
        let format = parser.parsePlaybackFormat(message)

        #expect(format?.codec == "AAC")
    }

    @Test func parsesQueueItemBeginWithEscapedKoreanTitle() {
        let message = """
        2026-06-19 09:33:47.908 Db Music[1937:1a202] [com.apple.amp.mediaplaybackcore:Engagement_Oversize] Event: {
            "event-type" = "item-begin";
            payload = {
                "item-metadata" = {
                    "item-duration" = "250.3333333333333";
                    "item-title" = "\\134Uae30\\134Uc5b5\\134Ub0a0 \\134Uadf8\\134Ub0a0\\134Uc774 \\134Uc640\\134Ub3c4";
                };
                "queue-item-id" = 3628;
                "queue-section-id" = 3620;
            };
        }
        """

        let item = parser.parseQueueItemBegin(message)

        #expect(item?.title == "기억날 그날이 와도")
        #expect(item?.duration == 250.3333333333333)
        #expect(item?.queueItemID == 3628)
        #expect(item?.queueSectionID == 3620)
    }

    @Test func parsesAudioFormatChangedForQueueItem() {
        let message = """
        2026-06-19 09:24:22.913 Db Music[1937:15653] [com.apple.amp.mediaplaybackcore:PlaybackEventStream_Oversize] emitEventType:audio-format-changed payload:{
            "item-audio-format-metadata" = {
                "active-format" = {
                    bd = 16;
                    grp = "audio-alac-stereo-44100-16";
                    sr = 44100;
                    tier = 2;
                };
            };
            "queue-item-id" = 3628;
            "queue-section-id" = 3620;
        }
        """

        let change = parser.parseAudioFormatChanged(message)

        #expect(change?.queueItemID == 3628)
        #expect(change?.queueSectionID == 3620)
        #expect(change?.groupID == "audio-alac-stereo-44100-16")
        #expect(change?.format?.codec == "ALAC")
        #expect(change?.format?.bitDepth == 16)
        #expect(change?.format?.sampleRate == 44_100)
    }

    @Test func parsesWrappedAudioFormatChangedPayload() {
        let message = """
        2026-06-19 10:34:40.913 Db Music[1937:15653] [com.apple.amp.mediaplaybackcore:PlaybackEventStream_Oversize] [EVS:urrH6fRUg] emitEventType:audio-format-changed payload:... atTime:2026-06-19 10:34:40+0900 | emitting payload [] event.id=348B4911-C58B-4697-87DE-F128B6EA15C8 payload={
            "item-audio-format-metadata" =     {
                "active-format" =         {
                    bd = 16;
                    br = 0;
                    chlay = 6619138;
                    chlayd = Stereo;
                    codec = 1634492771;
                    grp = "audio-alac-stereo-44100-16";
                    mul = 0;
                    ochlay = 0;
                    rdm = 0;
                    spz = 0;
                    sr = 44100;
                    tier = 2;
                    var = 021c170411bc9035f76b9cc091df55edeb452ee4e1582d5991f6e57384b28678;
                };
                "active-format-justification" = 100;
            };
            "queue-item-id" = 4039;
            "queue-section-id" = 3975;
        }
        """

        let change = parser.parseAudioFormatChanged(message)

        #expect(change?.queueItemID == 4039)
        #expect(change?.queueSectionID == 3975)
        #expect(change?.groupID == "audio-alac-stereo-44100-16")
        #expect(change?.format?.codec == "ALAC")
        #expect(change?.format?.bitDepth == 16)
        #expect(change?.format?.sampleRate == 44_100)
    }

    @Test func parsesAudioFormatPayloadWithoutEventTypeMarker() {
        let message = """
        payload={
            "item-audio-format-metadata" =     {
                "active-format" =         {
                    bd = 16;
                    grp = "audio-alac-stereo-44100-16";
                    sr = 44100;
                    tier = 2;
                };
                "active-format-justification" = 100;
            };
            "queue-item-id" = 4039;
            "queue-section-id" = 3975;
        }
        """

        let change = parser.parseAudioFormatChanged(message)

        #expect(change?.queueItemID == 4039)
        #expect(change?.groupID == "audio-alac-stereo-44100-16")
        #expect(change?.format?.codec == "ALAC")
    }

    @Test func keepsAudioFormatChangeScopedToQueueItem() {
        let itemBegin = """
        emitEventType:item-begin payload:{
            "item-duration" = 278;
            "item-title" = "\\134Uc0b0\\134Ub2e4\\134Ub294\\134Uac74 \\134Ub2e4 \\134Uadf8\\134Ub7f0\\134Uac8c \\134Uc544\\134Ub2c8\\134Uaca0\\134Ub2c8";
            "queue-item-id" = 3854;
            "queue-section-id" = 3818;
        }
        """
        let alacForAnotherItem = """
        emitEventType:audio-format-changed payload:{
            "item-audio-format-metadata" = {
                "active-format" = {
                    bd = 16;
                    grp = "audio-alac-stereo-44100-16";
                    sr = 44100;
                };
            };
            "queue-item-id" = 3856;
            "queue-section-id" = 3818;
        }
        """

        let item = parser.parseQueueItemBegin(itemBegin)
        let change = parser.parseAudioFormatChanged(alacForAnotherItem)

        #expect(item?.title == "산다는건 다 그런게 아니겠니")
        #expect(item?.queueItemID == 3854)
        #expect(change?.queueItemID == 3856)
        #expect(change?.format?.codec == "ALAC")
        #expect(item?.queueItemID != change?.queueItemID)
    }

    @Test func ignoresFormatChangesWithoutQueueItemPayload() {
        let message = "Audio format changed to PBAudioFormat.other."

        #expect(parser.parseAudioFormatChanged(message) == nil)
    }
}
