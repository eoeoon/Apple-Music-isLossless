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

    @Test func parsesFutureQueueAudioFormatChangedPayload() {
        let message = """
        2026-06-20 16:29:32.371 Db Music[80355:191090] [com.apple.amp.mediaplaybackcore:PlaybackEventStream_Oversize] [EVS:PrzwEF39o] emitEventType:audio-format-changed payload:… atTime:2026-06-20 16:29:36+0900 | emitting payload [] event.id=3A8A10E0-69E1-4ED0-8848-9BA568B479EA payload={
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
                    var = 9473f27e6caa00868eb00789f498633c8a419d4c3493fefc83bd505c01d131b3;
                };
                "active-format-justification" = 100;
            };
            "queue-item-id" = 7769;
            "queue-section-id" = 7757;
        }
        """

        let change = parser.parseAudioFormatChanged(message)

        #expect(change?.queueItemID == 7769)
        #expect(change?.queueSectionID == 7757)
        #expect(change?.groupID == "audio-alac-stereo-44100-16")
        #expect(change?.format?.codec == "ALAC")
        #expect(change?.format?.bitDepth == 16)
        #expect(change?.format?.sampleRate == 44_100)
    }

    @Test func parsesCompositeQueueSectionIDInAudioFormatChangedPayload() {
        let message = """
        2026-06-20 20:59:49.837 Db Music[80355:202666] [com.apple.amp.mediaplaybackcore:PlaybackEventStream_Oversize] [EVS:PrzwEF39o] emitEventType:audio-format-changed payload:… atTime:2026-06-20 20:59:54+0900 | emitting payload [] event.id=AEB2049A-6268-449F-A51B-B9EEA250EDA6 payload={
            "item-audio-format-metadata" =     {
                "active-format" =         {
                    bd = 24;
                    br = 0;
                    chlay = 6619138;
                    chlayd = Stereo;
                    codec = 1634492771;
                    grp = "audio-alac-stereo-48000-24";
                    sr = 48000;
                    tier = 2;
                };
                "active-format-justification" = 100;
            };
            "queue-item-id" = 9105;
            "queue-section-id" = "8881+9103";
        }
        """

        let change = parser.parseAudioFormatChanged(message)

        #expect(change?.queueItemID == 9105)
        #expect(change?.queueSectionID == 8881)
        #expect(change?.groupID == "audio-alac-stereo-48000-24")
        #expect(change?.format?.bitDepth == 24)
        #expect(change?.format?.sampleRate == 48_000)
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

    @Test func doesNotMixAudioFormatGroupFromDifferentPayload() {
        let message = """
        emitEventType:audio-format-changed payload={
            "item-audio-format-metadata" = {
                "active-format" = {
                    bd = 24;
                    grp = "audio-alac-stereo-48000-24";
                    sr = 48000;
                };
            };
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

        let change = parser.parseAudioFormatChanged(message)

        #expect(change?.queueItemID == 3702)
        #expect(change?.queueSectionID == 3608)
        #expect(change?.groupID == "audio-alac-stereo-96000-24")
        #expect(change?.format?.bitDepth == 24)
        #expect(change?.format?.sampleRate == 96_000)
    }

    @Test func parsesMultipleScopedAudioFormatPayloads() {
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

        let changes = parser.parseAudioFormatChanges(message)

        #expect(changes.map(\.queueItemID) == [3698, 3702])
        #expect(changes.map(\.groupID) == [
            "audio-alac-stereo-48000-24",
            "audio-alac-stereo-96000-24"
        ])
        #expect(changes.map { $0.format?.sampleRate } == [48_000, 96_000])
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

    @Test func parsesPlaybackItemTick() {
        let message = """
        2026-06-20 19:46:14.128 Df Music[80355:1d3532] [com.apple.amp.mediaplaybackcore:PlaybackEvents] |2026-06-20 19:46:14.125+0900 mus:PrzwEF39o 46 ⬜️ ┃┃┠──􀡐 ITEM TICK                  8502 8582                   ║ 2:38.48 ━━━━━━━━━━━━━━━━━━━━━━━━━●━━━ -0:20.51
        """

        let tick = parser.parsePlaybackItemTick(message)

        #expect(tick?.queueSectionID == 8502)
        #expect(tick?.queueItemID == 8582)
        #expect(tick?.position == 158.48)
        #expect(tick?.remainingTime == 20.51)
    }

    @Test func parsesPlaybackItemTickWithCompositeSectionID() {
        let message = """
        2026-06-20 21:09:33.657 Df Music[80355:209e73] [com.apple.amp.mediaplaybackcore:PlaybackEvents] |2026-06-20 21:09:33.652+0900 mus:PrzwEF39o 46 🟩 ┃ ┠──􀡐 ITEM TICK                  8881+9116 9118                   ║ 1:40.00 ━━━━━━━━━━━━●━━━━━━━━━━━━━━━━ -2:08.99
        """

        let tick = parser.parsePlaybackItemTick(message)

        #expect(tick?.queueSectionID == 8881)
        #expect(tick?.queueItemID == 9118)
        #expect(tick?.position == 100.0)
        #expect(tick?.remainingTime == 128.99)
    }

    @Test func parsesAssetQueueLink() {
        let message = """
        2026-06-20 19:43:34.989 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] [D:PrzwEF39o]-[AL] ┣ ASSET QUEUE                  Suspending asset task at 'loadItem' for 8502::8584 [prior item 8502::8582 not finished] [IT-8501]
        """

        let link = parser.parseAssetQueueLink(message)

        #expect(link?.queueSectionID == 8502)
        #expect(link?.priorQueueItemID == 8582)
        #expect(link?.nextQueueItemID == 8584)
    }

    @Test func parsesQueueItemsSnapshotLinks() {
        let message = """
        2026-06-20 20:59:49.446 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] [D:PrzwEF39o]-[SM] ┃ ┃ ┣◆ QUEUE EVENT PROCESSED   〔PlayingState〕- CoordinatorEvent.synchronizeQueueItemsToPlayer - items:[<ITMPAVItem: 0xbc9616300> (8881+9094::9096) romeo n juliet (feat. 유라), <ITMPAVItem: 0xbc8fda300> (8881+9103::9105) I Really Want to Stay At Your House, <ITMPAVItem: 0xbcab55880> (8881+9088::9090) 동경소녀] hasLoadedAllItems:false
        """

        let links = parser.parseQueueItemsSnapshotLinks(message)

        #expect(links.count == 2)
        #expect(links[0].queueSectionID == 8881)
        #expect(links[0].priorQueueItemID == 9096)
        #expect(links[0].nextQueueItemID == 9105)
        #expect(links[1].queueSectionID == 8881)
        #expect(links[1].priorQueueItemID == 9105)
        #expect(links[1].nextQueueItemID == 9090)
    }

    @Test func parsesPlayerQueueSnapshotLinks() throws {
        let message = """
        2026-06-20 21:16:21.774 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] [D:PrzwEF39o]-[AV] ┃ ┃ ┃ ┣ PLAYER PROCESSING      InternalPlayerController - Queue->Player synchronization completed - player:P/QM 0x0000000bc4468080 playerItems:[<AVPlayerItem: 0xbcc5a3cc0> I/HBN [8881::8929] <ITMPAVItem: 0xbca39c700> (8881::8929) 가질 수 없는 너], <AVPlayerItem: 0xbcc494d70> I/IBB [8881+9139::9141] <ITMPAVItem: 0xbcab4dc00> (8881+9139::9141) 보라빛 밤], <AVPlayerItem: 0xbcc5a12c0> I/WQB [8881::8931] <ITMPAVItem: 0xbcbf1f100> (8881::8931) 그녀가 웃잖아]]
        """

        let snapshot = try #require(parser.parseQueueSnapshot(message))

        #expect(snapshot.source == .playerQueue)
        #expect(snapshot.items.map(\.queueItemID) == [8929, 9141, 8931])
        #expect(snapshot.items.map(\.queueSectionID) == [8881, 8881, 8881])
        #expect(snapshot.links.map(\.priorQueueItemID) == [8929, 9141])
        #expect(snapshot.links.map(\.nextQueueItemID) == [9141, 8931])
    }

    @Test func parsesAssetQueueStateSnapshotLinks() throws {
        let message = """
        2026-06-20 21:16:22.349 Df Music[80355:160ef2] [com.apple.amp.mediaplaybackcore:Playback] [D:PrzwEF39o]-[AL] ┣ ASSET QUEUE                  State: AssetQueueState(currentQueueItem: Optional(<ITMPAVItem: 0xbca39c700> (8881::8929) 가질 수 없는 너), loadedQueueItems: [<ITMPAVItem: 0xbca39c700> (8881::8929) 가질 수 없는 너, <ITMPAVItem: 0xbcbf1c380> (8881+9147::9149) Into the I-Land, <ITMPAVItem: 0xbcab4dc00> (8881+9139::9141) 보라빛 밤], unskippableError: nil, hasLoadedAllItems: false, isPrefixedWithSilentlyFailedItems: false) [IT-8880]
        """

        let snapshot = try #require(parser.parseQueueSnapshot(message))

        #expect(snapshot.source == .assetQueueState)
        #expect(snapshot.items.map(\.queueItemID) == [8929, 9149, 9141])
        #expect(snapshot.items.map(\.queueSectionID) == [8881, 8881, 8881])
        #expect(snapshot.links.map(\.priorQueueItemID) == [8929, 9149])
        #expect(snapshot.links.map(\.nextQueueItemID) == [9149, 9141])
    }
}
