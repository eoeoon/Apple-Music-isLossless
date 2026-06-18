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
}
