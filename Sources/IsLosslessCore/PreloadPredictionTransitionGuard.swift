import Foundation

public struct PreloadPredictionTransitionGuard: Equatable, Sendable {
    public let previousQueueItemID: Int
    public let predictedQueueItemID: Int
    public let predictedFormat: AudioFormat
    public let appliedAt: Date
    public let expiresAt: Date

    public init(
        previousQueueItemID: Int,
        predictedQueueItemID: Int,
        predictedFormat: AudioFormat,
        appliedAt: Date,
        expiresAt: Date
    ) {
        self.previousQueueItemID = previousQueueItemID
        self.predictedQueueItemID = predictedQueueItemID
        self.predictedFormat = predictedFormat
        self.appliedAt = appliedAt
        self.expiresAt = expiresAt
    }

    public func evaluate(queueItemID: Int, now: Date) -> PreloadPredictionTransitionDecision {
        guard now <= expiresAt else {
            return .expired
        }

        if queueItemID == previousQueueItemID {
            return .ignoredStale(expectedQueueItemID: predictedQueueItemID)
        }

        if queueItemID == predictedQueueItemID {
            return .confirmedPredicted
        }

        return .miss
    }
}

public enum PreloadPredictionTransitionDecision: Equatable, Sendable {
    case accepted
    case ignoredStale(expectedQueueItemID: Int)
    case confirmedPredicted
    case miss
    case expired
}
