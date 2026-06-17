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

    @Test func preservesDecimalSampleRates() {
        #expect(formatter.formatSampleRate(44_100) == "44.1kHz")
    }

    @Test func showsEmDashWhenNotPlaying() {
        let title = formatter.title(
            for: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            status: .notPlaying
        )

        #expect(title == "—")
    }
}
