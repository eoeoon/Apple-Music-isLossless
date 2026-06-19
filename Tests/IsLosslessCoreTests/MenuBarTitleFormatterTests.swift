import Testing
@testable import IsLosslessCore

@Suite("Menu bar title formatting")
struct MenuBarTitleFormatterTests {
    private let formatter = MenuBarTitleFormatter()

    @Test func formatsBitDepthAndSampleRate() {
        let title = formatter.title(
            for: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            status: .detected
        )

        #expect(title == "24비트 96kHz")
    }

    @Test func formatsAACWithBitRateOnly() {
        let title = formatter.title(
            for: AudioFormat(codec: "AAC", bitRate: 256, sampleRate: 48_000),
            status: .detected
        )

        #expect(title == "AAC 256kbps")
    }

    @Test func formatsAACWithSampleRateWhenBitRateIsMissing() {
        let title = formatter.title(
            for: AudioFormat(codec: "AAC", sampleRate: 44_100),
            status: .detected
        )

        #expect(title == "AAC 44.1kHz")
    }

    @Test func formatsALACWithBitDepthAndSampleRate() {
        let title = formatter.title(
            for: AudioFormat(codec: "ALAC", bitDepth: 24, sampleRate: 48_000),
            status: .detected
        )

        #expect(title == "ALAC 24비트 48kHz")
    }

    @Test func preservesDecimalSampleRates() {
        #expect(formatter.formatSampleRate(44_100) == "44.1kHz")
    }

    @Test func showsAppNameWhenNotPlaying() {
        let title = formatter.title(
            for: nil,
            status: .notPlaying
        )

        #expect(title == "isLossless")
    }

    @Test func usesInactiveTitleForUnverifiedLossless() {
        let title = formatter.title(
            for: nil,
            status: .unverifiedLossless
        )

        #expect(title == "—")
    }

    @Test func preservesFormatWhenPaused() {
        let title = formatter.title(
            for: AudioFormat(codec: "ALAC", bitDepth: 24, sampleRate: 96_000),
            status: .paused
        )

        #expect(title == "ALAC 24비트 96kHz")
    }
}
