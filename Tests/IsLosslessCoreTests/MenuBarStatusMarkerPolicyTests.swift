import Testing
@testable import IsLosslessCore

@Suite("Menu bar status marker policy")
struct MenuBarStatusMarkerPolicyTests {
    @Test func transitioningReturnsNone() {
        let marker = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .failed,
            currentFormat: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            outputSampleRate: 44_100,
            outputBitDepth: 16,
            isTransitioning: true
        )

        #expect(marker == .none)
    }

    @Test func failedReturnsRedFilled() {
        let marker = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .failed,
            currentFormat: nil,
            outputSampleRate: nil,
            outputBitDepth: nil,
            isTransitioning: false
        )

        #expect(marker == .filled(.red))
    }

    @Test func matchingSampleRateAndBitDepthReturnsGreenFilled() {
        let marker = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            outputSampleRate: 96_000,
            outputBitDepth: 24,
            isTransitioning: false
        )

        #expect(marker == .filled(.green))
    }

    @Test func matchingSampleRateAndDifferentBitDepthReturnsGreenOutline() {
        let marker = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            outputSampleRate: 96_000,
            outputBitDepth: 16,
            isTransitioning: false
        )

        #expect(marker == .outline(.green))
    }

    @Test func matchingSampleRateWithMissingBitDepthReturnsGreenFilled() {
        let missingCurrentBitDepth = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(sampleRate: 44_100),
            outputSampleRate: 44_100,
            outputBitDepth: 24,
            isTransitioning: false
        )
        let missingOutputBitDepth = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 16, sampleRate: 44_100),
            outputSampleRate: 44_100,
            outputBitDepth: nil,
            isTransitioning: false
        )

        #expect(missingCurrentBitDepth == .filled(.green))
        #expect(missingOutputBitDepth == .filled(.green))
    }

    @Test func currentSampleRateHigherThanOutputReturnsYellowFilled() {
        let marker = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            outputSampleRate: 44_100,
            outputBitDepth: 24,
            isTransitioning: false
        )

        #expect(marker == .filled(.yellow))
    }

    @Test func currentSampleRateLowerThanOutputReturnsGreenOutline() {
        let marker = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 16, sampleRate: 44_100),
            outputSampleRate: 96_000,
            outputBitDepth: 24,
            isTransitioning: false
        )

        #expect(marker == .outline(.green))
    }

    @Test func missingSampleRateReturnsNone() {
        let missingCurrentSampleRate = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 24),
            outputSampleRate: 96_000,
            outputBitDepth: 24,
            isTransitioning: false
        )
        let missingOutputSampleRate = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            outputSampleRate: nil,
            outputBitDepth: 24,
            isTransitioning: false
        )

        #expect(missingCurrentSampleRate == .none)
        #expect(missingOutputSampleRate == .none)
    }

    @Test func sampleRatesWithinToleranceAreTreatedAsMatch() {
        let marker = MenuBarStatusMarkerPolicy.marker(
            detectionStatus: .detected,
            currentFormat: AudioFormat(bitDepth: 24, sampleRate: 96_000),
            outputSampleRate: 96_000.49,
            outputBitDepth: 24,
            isTransitioning: false
        )

        #expect(marker == .filled(.green))
    }
}
