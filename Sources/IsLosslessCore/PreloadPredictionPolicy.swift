import Foundation

public enum PreloadPredictionPlaybackState: Equatable, Sendable {
    case unknown
    case notRunning
    case stopped
    case paused
    case playing
}

public struct PreloadPredictionSchedule: Equatable, Sendable {
    public let currentQueueItemID: Int
    public let nextQueueItemID: Int
    public let fireAfter: TimeInterval
    public let remainingTime: TimeInterval

    public init(
        currentQueueItemID: Int,
        nextQueueItemID: Int,
        fireAfter: TimeInterval,
        remainingTime: TimeInterval
    ) {
        self.currentQueueItemID = currentQueueItemID
        self.nextQueueItemID = nextQueueItemID
        self.fireAfter = fireAfter
        self.remainingTime = remainingTime
    }
}

public enum PreloadPredictionDecision: Equatable, Sendable {
    case schedule(PreloadPredictionSchedule)
    case cancel(PreloadPredictionSkipReason)
}

public enum PreloadPredictionValidation: Equatable, Sendable {
    case apply(remainingTime: TimeInterval)
    case skip(PreloadPredictionSkipReason)
}

public struct PreloadPredictionWatchdogSchedule: Equatable, Sendable {
    public let interval: TimeInterval
    public let remainingTime: TimeInterval
    public let shouldApply: Bool
    public let shouldStartActivity: Bool

    public init(
        interval: TimeInterval,
        remainingTime: TimeInterval,
        shouldApply: Bool,
        shouldStartActivity: Bool
    ) {
        self.interval = interval
        self.remainingTime = remainingTime
        self.shouldApply = shouldApply
        self.shouldStartActivity = shouldStartActivity
    }
}

public enum PreloadPredictionWatchdogDecision: Equatable, Sendable {
    case schedule(PreloadPredictionWatchdogSchedule)
    case cancel(PreloadPredictionSkipReason)
}

public enum PreloadPredictionSkipReason: String, Equatable, Sendable {
    case notPlaying = "not-playing"
    case missingCurrentRecord = "missing-current"
    case missingNextRecord = "missing-next"
    case missingDuration = "missing-duration"
    case missingPlayerPosition = "missing-position"
    case noRemainingTime = "no-remaining-time"
    case staleTrack = "stale-track"
    case staleCurrentRecord = "stale-current"
    case staleNextRecord = "stale-next"
    case remainingTimeTooLarge = "remaining-too-large"
    case matchingFormat = "matching-format"
}

public struct PreloadPredictionPolicy: Sendable {
    public let switchLeadTime: TimeInterval
    public let validationWindow: TimeInterval

    public init(switchLeadTime: TimeInterval = 3.0, validationWindow: TimeInterval = 3.5) {
        self.switchLeadTime = switchLeadTime
        self.validationWindow = validationWindow
    }

    public func schedule(
        playbackState: PreloadPredictionPlaybackState,
        duration: Double?,
        playerPosition: Double?,
        currentRecord: AppleMusicPreloadRecord?,
        nextRecord: AppleMusicPreloadRecord?
    ) -> PreloadPredictionDecision {
        guard playbackState == .playing else {
            return .cancel(.notPlaying)
        }

        guard let currentRecord else {
            return .cancel(.missingCurrentRecord)
        }

        guard let nextRecord else {
            return .cancel(.missingNextRecord)
        }

        guard !formatsMatch(currentRecord.format, nextRecord.format) else {
            return .cancel(.matchingFormat)
        }

        guard let duration,
              duration.isFinite,
              duration > 0 else {
            return .cancel(.missingDuration)
        }

        guard let playerPosition,
              playerPosition.isFinite,
              playerPosition >= 0 else {
            return .cancel(.missingPlayerPosition)
        }

        let remainingTime = duration - playerPosition
        guard remainingTime > 0 else {
            return .cancel(.noRemainingTime)
        }

        return .schedule(
            PreloadPredictionSchedule(
                currentQueueItemID: currentRecord.queueItemID,
                nextQueueItemID: nextRecord.queueItemID,
                fireAfter: max(remainingTime - switchLeadTime, 0),
                remainingTime: remainingTime
            )
        )
    }

    public func validate(
        expectedTrackIdentity: String?,
        actualTrackIdentity: String?,
        expectedCurrentQueueItemID: Int,
        expectedNextQueueItemID: Int,
        playbackState: PreloadPredictionPlaybackState,
        duration: Double?,
        playerPosition: Double?,
        currentRecord: AppleMusicPreloadRecord?,
        nextRecord: AppleMusicPreloadRecord?
    ) -> PreloadPredictionValidation {
        guard playbackState == .playing else {
            return .skip(.notPlaying)
        }

        guard expectedTrackIdentity == actualTrackIdentity else {
            return .skip(.staleTrack)
        }

        guard currentRecord?.queueItemID == expectedCurrentQueueItemID else {
            return .skip(.staleCurrentRecord)
        }

        guard nextRecord?.queueItemID == expectedNextQueueItemID else {
            return .skip(.staleNextRecord)
        }

        guard let duration,
              duration.isFinite,
              duration > 0 else {
            return .skip(.missingDuration)
        }

        guard let playerPosition,
              playerPosition.isFinite,
              playerPosition >= 0 else {
            return .skip(.missingPlayerPosition)
        }

        let remainingTime = duration - playerPosition
        guard remainingTime > 0 else {
            return .skip(.noRemainingTime)
        }

        guard remainingTime <= validationWindow else {
            return .skip(.remainingTimeTooLarge)
        }

        return .apply(remainingTime: remainingTime)
    }

    public func watchdog(
        playbackState: PreloadPredictionPlaybackState,
        duration: Double?,
        playerPosition: Double?,
        currentRecord: AppleMusicPreloadRecord?,
        nextRecord: AppleMusicPreloadRecord?
    ) -> PreloadPredictionWatchdogDecision {
        guard playbackState == .playing else {
            return .cancel(.notPlaying)
        }

        guard let currentRecord else {
            return .cancel(.missingCurrentRecord)
        }

        guard let nextRecord else {
            return .cancel(.missingNextRecord)
        }

        guard !formatsMatch(currentRecord.format, nextRecord.format) else {
            return .cancel(.matchingFormat)
        }

        guard let duration,
              duration.isFinite,
              duration > 0 else {
            return .cancel(.missingDuration)
        }

        guard let playerPosition,
              playerPosition.isFinite,
              playerPosition >= 0 else {
            return .cancel(.missingPlayerPosition)
        }

        let remainingTime = duration - playerPosition
        guard remainingTime > 0 else {
            return .cancel(.noRemainingTime)
        }

        let interval: TimeInterval
        if remainingTime > 30 {
            interval = 5
        } else if remainingTime > 8 {
            interval = 1
        } else {
            interval = 0.5
        }

        return .schedule(
            PreloadPredictionWatchdogSchedule(
                interval: interval,
                remainingTime: remainingTime,
                shouldApply: remainingTime <= validationWindow,
                shouldStartActivity: remainingTime <= 30
            )
        )
    }

    private func formatsMatch(_ lhs: AudioFormat, _ rhs: AudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate && lhs.bitDepth == rhs.bitDepth
    }
}
