import Foundation
import Testing
@testable import IsLosslessCore

@Suite("Preload prediction transition guard")
struct PreloadPredictionTransitionGuardTests {
    @Test func ignoresPreviousQueueItemImmediatelyAfterPrediction() {
        let guardState = guardState(previous: 3662, predicted: 3674)

        #expect(guardState.evaluate(
            queueItemID: 3662,
            now: Date(timeIntervalSince1970: 104)
        ) == .ignoredStale(expectedQueueItemID: 3674))
    }

    @Test func confirmsPredictedQueueItemInsideWindow() {
        let guardState = guardState(previous: 3662, predicted: 3674)

        #expect(guardState.evaluate(
            queueItemID: 3674,
            now: Date(timeIntervalSince1970: 104)
        ) == .confirmedPredicted)
    }

    @Test func treatsDifferentQueueItemAsMissInsideWindow() {
        let guardState = guardState(previous: 3662, predicted: 3674)

        #expect(guardState.evaluate(
            queueItemID: 9999,
            now: Date(timeIntervalSince1970: 104)
        ) == .miss)
    }

    @Test func expiresAfterWindow() {
        let guardState = guardState(previous: 3662, predicted: 3674)

        #expect(guardState.evaluate(
            queueItemID: 3662,
            now: Date(timeIntervalSince1970: 109)
        ) == .expired)
    }

    private func guardState(previous: Int, predicted: Int) -> PreloadPredictionTransitionGuard {
        PreloadPredictionTransitionGuard(
            previousQueueItemID: previous,
            predictedQueueItemID: predicted,
            predictedFormat: AudioFormat(codec: "ALAC", bitDepth: 16, sampleRate: 44_100),
            appliedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 108)
        )
    }
}
