import Testing
@testable import IsLosslessCore

@Suite("Audio output switch policy")
struct AudioOutputSwitchPolicyTests {
    private let policy = AudioOutputSwitchPolicy()

    @Test func targetsPhysicalFormatForAlacWithBitDepth() {
        let target = policy.target(
            status: .detected,
            format: AudioFormat(codec: "ALAC", bitDepth: 24, sampleRate: 96_000),
            appleScriptSampleRate: 44_100,
            isPlaybackActive: true
        )

        #expect(target == .physicalFormat(sampleRate: 96_000, bitDepth: 24))
    }

    @Test func targetsSampleRateOnlyForAlacWithoutBitDepth() {
        let target = policy.target(
            status: .detected,
            format: AudioFormat(codec: "ALAC", sampleRate: 96_000),
            appleScriptSampleRate: 44_100,
            isPlaybackActive: true
        )

        #expect(target == .nominalSampleRate(96_000))
    }

    @Test func usesAppleScriptSampleRateForNonLosslessFormats() {
        let target = policy.target(
            status: .detected,
            format: AudioFormat(codec: "AAC", bitRate: 256, sampleRate: 48_000),
            appleScriptSampleRate: 44_100,
            isPlaybackActive: true
        )

        #expect(target == .nominalSampleRate(44_100))
    }

    @Test func ignoresInactiveOrUnresolvedStates() {
        let format = AudioFormat(codec: "ALAC", bitDepth: 24, sampleRate: 96_000)
        let inactiveStatuses: [DetectionStatus] = [
            .detecting,
            .failed,
            .unverifiedLossless,
            .notPlaying,
            .appleMusicNotRunning
        ]

        for status in inactiveStatuses {
            #expect(policy.target(
                status: status,
                format: format,
                appleScriptSampleRate: 96_000,
                isPlaybackActive: true
            ) == nil)
        }

        #expect(policy.target(
            status: .detected,
            format: format,
            appleScriptSampleRate: 96_000,
            isPlaybackActive: false
        ) == nil)
    }
}
