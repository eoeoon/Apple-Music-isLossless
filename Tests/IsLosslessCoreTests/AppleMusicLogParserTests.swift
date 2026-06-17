import Testing
@testable import IsLosslessCore

@Suite("Apple Music log parsing")
struct AppleMusicLogParserTests {
    private let parser = AppleMusicLogParser()

    @Test func parsesCoreAudioStyleLosslessMessage() {
        let message = "ACAppleLosslessDecoder.cpp Input format: 96000 Hz, 24-bit source"
        let format = parser.parse(message)

        #expect(format?.bitDepth == 24)
        #expect(format?.sampleRate == 96_000)
    }

    @Test func parsesMusicSampleRateFields() {
        let message = "audioCapabilities: asbdSampleRate = 44100, sdBitDepth = 16"
        let format = parser.parse(message)

        #expect(format?.bitDepth == 16)
        #expect(format?.sampleRate == 44_100)
    }
}
