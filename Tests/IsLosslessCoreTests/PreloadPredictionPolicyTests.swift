import Foundation
import Testing
@testable import IsLosslessCore

@Suite("Preload prediction policy")
struct PreloadPredictionPolicyTests {
    private let policy = PreloadPredictionPolicy()

    @Test func schedulesWhenPlayingWithCurrentAndNextRecords() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        let decision = policy.schedule(
            playbackState: .playing,
            duration: 250,
            playerPosition: 245.8,
            currentRecord: current,
            nextRecord: next
        )

        guard case .schedule(let schedule) = decision else {
            Issue.record("Expected prediction to be scheduled")
            return
        }

        #expect(schedule.currentQueueItemID == 3779)
        #expect(schedule.nextQueueItemID == 3995)
        #expect(abs(schedule.fireAfter - 1.2) < 0.001)
        #expect(abs(schedule.remainingTime - 4.2) < 0.001)
    }

    @Test func doesNotScheduleWhenPausedStoppedOrNotRunning() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        for playbackState in [PreloadPredictionPlaybackState.paused, .stopped, .notRunning] {
            let decision = policy.schedule(
                playbackState: playbackState,
                duration: 250,
                playerPosition: 248.8,
                currentRecord: current,
                nextRecord: next
            )

            #expect(decision == .cancel(.notPlaying))
        }
    }

    @Test func doesNotScheduleWithoutDurationOrPlayerPosition() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        #expect(policy.schedule(
            playbackState: .playing,
            duration: nil,
            playerPosition: 248.8,
            currentRecord: current,
            nextRecord: next
        ) == .cancel(.missingDuration))

        #expect(policy.schedule(
            playbackState: .playing,
            duration: 250,
            playerPosition: nil,
            currentRecord: current,
            nextRecord: next
        ) == .cancel(.missingPlayerPosition))
    }

    @Test func doesNotScheduleWhenCurrentAndNextFormatsMatch() throws {
        let current = try #require(record(id: 3779, bitDepth: 16, sampleRate: 44_100))
        let next = try #require(record(id: 3995, bitDepth: 16, sampleRate: 44_100))

        #expect(policy.schedule(
            playbackState: .playing,
            duration: 250,
            playerPosition: 120,
            currentRecord: current,
            nextRecord: next
        ) == .cancel(.matchingFormat))
    }

    @Test func validationSkipsStaleTrackDifferentQueueItemAndTooMuchRemainingTime() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))
        let differentNext = try #require(record(id: 4100, bitDepth: 24, sampleRate: 48_000))

        #expect(policy.validate(
            expectedTrackIdentity: "track-a",
            actualTrackIdentity: "track-b",
            expectedCurrentQueueItemID: 3779,
            expectedNextQueueItemID: 3995,
            playbackState: .playing,
            duration: 250,
            playerPosition: 249.8,
            currentRecord: current,
            nextRecord: next
        ) == .skip(.staleTrack))

        #expect(policy.validate(
            expectedTrackIdentity: "track-a",
            actualTrackIdentity: "track-a",
            expectedCurrentQueueItemID: 3779,
            expectedNextQueueItemID: 3995,
            playbackState: .playing,
            duration: 250,
            playerPosition: 249.8,
            currentRecord: current,
            nextRecord: differentNext
        ) == .skip(.staleNextRecord))

        #expect(policy.validate(
            expectedTrackIdentity: "track-a",
            actualTrackIdentity: "track-a",
            expectedCurrentQueueItemID: 3779,
            expectedNextQueueItemID: 3995,
            playbackState: .playing,
            duration: 250,
            playerPosition: 246,
            currentRecord: current,
            nextRecord: next
        ) == .skip(.remainingTimeTooLarge))
    }

    @Test func validationAppliesInsideEndWindow() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        let validation = policy.validate(
            expectedTrackIdentity: "track-a",
            actualTrackIdentity: "track-a",
            expectedCurrentQueueItemID: 3779,
            expectedNextQueueItemID: 3995,
            playbackState: .playing,
            duration: 250,
            playerPosition: 247,
            currentRecord: current,
            nextRecord: next
        )

        guard case .apply(let remainingTime) = validation else {
            Issue.record("Expected prediction validation to apply")
            return
        }

        #expect(abs(remainingTime - 3) < 0.001)
    }

    @Test func watchdogUsesLowFrequencyWhenFarFromEnd() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        let decision = policy.watchdog(
            playbackState: .playing,
            duration: 250,
            playerPosition: 130,
            currentRecord: current,
            nextRecord: next
        )

        #expect(decision == .schedule(PreloadPredictionWatchdogSchedule(
            interval: 5,
            remainingTime: 120,
            shouldApply: false,
            shouldStartActivity: false
        )))
    }

    @Test func watchdogUsesOneSecondInsideThirtySeconds() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        let decision = policy.watchdog(
            playbackState: .playing,
            duration: 250,
            playerPosition: 230,
            currentRecord: current,
            nextRecord: next
        )

        #expect(decision == .schedule(PreloadPredictionWatchdogSchedule(
            interval: 1,
            remainingTime: 20,
            shouldApply: false,
            shouldStartActivity: true
        )))
    }

    @Test func watchdogUsesHighFrequencyNearEnd() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        let decision = policy.watchdog(
            playbackState: .playing,
            duration: 250,
            playerPosition: 244,
            currentRecord: current,
            nextRecord: next
        )

        #expect(decision == .schedule(PreloadPredictionWatchdogSchedule(
            interval: 0.5,
            remainingTime: 6,
            shouldApply: false,
            shouldStartActivity: true
        )))
    }

    @Test func watchdogCanApplyInsideValidationWindow() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        let decision = policy.watchdog(
            playbackState: .playing,
            duration: 250,
            playerPosition: 246.5,
            currentRecord: current,
            nextRecord: next
        )

        #expect(decision == .schedule(PreloadPredictionWatchdogSchedule(
            interval: 0.5,
            remainingTime: 3.5,
            shouldApply: true,
            shouldStartActivity: true
        )))
    }

    @Test func watchdogCancelsWhenPredictionInputsAreMissingOrInactive() throws {
        let current = try #require(record(id: 3779))
        let next = try #require(record(id: 3995))

        #expect(policy.watchdog(
            playbackState: .paused,
            duration: 250,
            playerPosition: 230,
            currentRecord: current,
            nextRecord: next
        ) == .cancel(.notPlaying))

        #expect(policy.watchdog(
            playbackState: .playing,
            duration: 250,
            playerPosition: 230,
            currentRecord: nil,
            nextRecord: next
        ) == .cancel(.missingCurrentRecord))

        #expect(policy.watchdog(
            playbackState: .playing,
            duration: 250,
            playerPosition: 230,
            currentRecord: current,
            nextRecord: nil
        ) == .cancel(.missingNextRecord))
    }

    @Test func watchdogCancelsWhenCurrentAndNextFormatsMatch() throws {
        let current = try #require(record(id: 3779, bitDepth: 24, sampleRate: 96_000))
        let next = try #require(record(id: 3995, bitDepth: 24, sampleRate: 96_000))

        #expect(policy.watchdog(
            playbackState: .playing,
            duration: 250,
            playerPosition: 230,
            currentRecord: current,
            nextRecord: next
        ) == .cancel(.matchingFormat))
    }

    private func record(id: Int, bitDepth: Int = 16, sampleRate: Double = 44_100) -> AppleMusicPreloadRecord? {
        AppleMusicPreloadRecord(
            queueItem: AppleMusicQueueItemBegin(
                title: "Song \(id)",
                duration: 250.9,
                queueItemID: id,
                queueSectionID: 3975
            ),
            formatChange: AppleMusicAudioFormatChange(
                queueItemID: id,
                queueSectionID: 3975,
                groupID: "audio-alac-stereo-44100-16",
                format: AudioFormat(codec: "ALAC", bitDepth: bitDepth, sampleRate: sampleRate)
            ),
            savedAt: Date(timeIntervalSince1970: Double(id))
        )
    }
}
