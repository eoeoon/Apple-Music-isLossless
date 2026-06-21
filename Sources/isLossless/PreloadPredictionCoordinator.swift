#if os(macOS)
import Foundation
import IsLosslessCore

@MainActor
final class PreloadPredictionCoordinator {
    typealias ValidationProvider = @MainActor () -> PreloadPredictionState
    typealias PredictionApplier = @MainActor (AppleMusicPreloadRecord, String?, Int) -> AudioOutputSwitchResult?

    private let policy = PreloadPredictionPolicy()
    private let confirmationTimeout: TimeInterval = 6
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingKey: PredictionKey?
    private var pendingDeadline: Date?
    private var watchdogWorkItem: DispatchWorkItem?
    private var watchdogKey: PredictionKey?
    private var watchdogInterval: TimeInterval?
    private var activity: NSObjectProtocol?
    private var appliedPrediction: AppliedPrediction?
    private var confirmedPrediction: ConfirmedPrediction?
    private var lastMatchingFormatSkipKey: PredictionKey?
    var onPendingStateChanged: ((Bool) -> Void)?

    var hasPendingPrediction: Bool {
        pendingKey != nil
    }

    func reschedule(
        for state: PreloadPredictionState,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) {
        reportAppliedPredictionOutcome(for: state)

        switch policy.schedule(
            playbackState: state.playbackState,
            duration: state.duration,
            playerPosition: state.playerPosition,
            currentRecord: state.currentRecord,
            nextRecord: state.nextRecord
        ) {
        case .cancel(let reason):
            let logReason = cancellationReason(for: state, fallback: reason.rawValue)
            if reason == .matchingFormat,
               pendingWorkItem == nil,
               watchdogWorkItem == nil {
                debugLog("skipped reason=\(logReason)")
            }
            cancel(reason: logReason)

        case .schedule(let schedule):
            guard let key = PredictionKey(state: state) else {
                cancel(reason: "missing-key")
                return
            }

            let deadline = Date().addingTimeInterval(schedule.fireAfter)

            if pendingKey == key,
               let pendingDeadline,
               abs(deadline.timeIntervalSince(pendingDeadline)) < 0.25 {
                scheduleWatchdog(
                    key: key,
                    state: state,
                    validate: validate,
                    apply: apply
                )
                return
            }

            if pendingKey == key {
                clearPending(logReason: "position-changed")
            } else if let pendingKey {
                clearPending(logReason: cancellationReason(replacing: pendingKey, with: key))
            } else {
                clearPending(logReason: nil)
            }

            if appliedPrediction?.key == key {
                return
            }

            if isConfirmedTransition(key) {
                return
            }

            scheduleOneShot(
                key: key,
                fireAfter: schedule.fireAfter,
                validate: validate,
                apply: apply
            )
            scheduleWatchdog(
                key: key,
                state: state,
                validate: validate,
                apply: apply
            )
            debugLog(
                "schedule",
                "current=\(schedule.currentQueueItemID) next=\(schedule.nextQueueItemID) fireIn=\(formatSeconds(schedule.fireAfter)) target=\(formatDescription(state.nextRecord?.format))"
            )
        }
    }

    func cancel(reason: String) {
        clearPending(logReason: reason)
    }

    func cancelIfPendingReordered(_ result: AppleMusicQueueSnapshotStoreResult) {
        guard let pendingKey,
              let changedLink = result.changedLinks.first(where: {
                  $0.priorQueueItemID == pendingKey.currentQueueItemID
                      && $0.nextQueueItemID != pendingKey.nextQueueItemID
              }) else {
            return
        }

        clearPending(
            logReason: "queue-reordered current=\(pendingKey.currentQueueItemID) oldNext=\(pendingKey.nextQueueItemID) newNext=\(changedLink.nextQueueItemID) source=\(result.snapshot.source.logDescription)"
        )
    }

    func observeState(_ state: PreloadPredictionState) {
        reportAppliedPredictionOutcome(for: state)

        switch state.playbackState {
        case .paused:
            clearPending(logReason: "paused")
        case .stopped:
            clearPending(logReason: "stopped")
        case .notRunning:
            clearPending(logReason: "not-running")
        default:
            break
        }

        if let pendingKey,
           PredictionKey(state: state) != pendingKey {
            clearPending(logReason: "state-changed")
        }
    }

    func applyEventPrediction(
        for state: PreloadPredictionState,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) -> AudioOutputSwitchResult? {
        reportAppliedPredictionOutcome(for: state)

        guard state.playbackState == .playing else {
            clearPending(logReason: "not-playing")
            return nil
        }

        guard let key = PredictionKey(state: state),
              let nextRecord = state.nextRecord else {
            clearPending(logReason: "missing-current-or-next")
            return nil
        }

        guard !isConfirmedTransition(key) else {
            debugLog("skip", "reason=confirmed-transition current=\(key.currentQueueItemID) next=\(key.nextQueueItemID)")
            return nil
        }

        guard let duration = state.duration,
              let playerPosition = state.playerPosition else {
            return nil
        }

        let remainingTime = duration - playerPosition
        guard remainingTime >= 0 else {
            return nil
        }

        if let currentRecord = state.currentRecord {
            guard !formatsMatch(currentRecord.format, nextRecord.format) else {
                if pendingKey == key {
                    clearPending(logReason: "matching-format")
                }
                if lastMatchingFormatSkipKey != key {
                    debugLog("skipped reason=matching-format")
                    lastMatchingFormatSkipKey = key
                }
                return nil
            }
        }
        lastMatchingFormatSkipKey = nil

        guard appliedPrediction?.key != key else {
            return nil
        }

        guard remainingTime <= policy.validationWindow else {
            scheduleEventOneShotIfNeeded(
                key: key,
                nextRecord: nextRecord,
                fireAfter: max(remainingTime - policy.switchLeadTime, 0),
                validate: validate,
                apply: apply
            )
            return nil
        }

        debugLog(
            "apply",
            "trigger=event current=\(key.currentQueueItemID) next=\(nextRecord.queueItemID) remaining=\(formatSeconds(remainingTime)) target=\(formatDescription(nextRecord.format))"
        )
        return applyPrediction(
            nextRecord,
            key: key,
            trackIdentity: state.trackIdentity,
            remainingTime: remainingTime,
            apply: apply,
            stopReason: "event-applied"
        )
    }

    private func scheduleEventOneShotIfNeeded(
        key: PredictionKey,
        nextRecord: AppleMusicPreloadRecord,
        fireAfter: TimeInterval,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) {
        let deadline = Date().addingTimeInterval(fireAfter)
        if pendingKey == key,
           let pendingDeadline,
           abs(deadline.timeIntervalSince(pendingDeadline)) < 0.25 {
            return
        }

        if pendingKey == key {
            clearPending(logReason: "event-deadline-changed")
        } else if let pendingKey {
            clearPending(logReason: cancellationReason(replacing: pendingKey, with: key))
        }

        scheduleOneShot(
            key: key,
            fireAfter: fireAfter,
            validate: validate,
            apply: apply
        )
            debugLog(
                "schedule",
                "current=\(key.currentQueueItemID) next=\(nextRecord.queueItemID) fireIn=\(formatSeconds(fireAfter)) target=\(formatDescription(nextRecord.format))"
            )
    }

    func shouldDeferOutputSwitch(for state: PreloadPredictionState, now: Date = Date()) -> Bool {
        if var confirmedPrediction {
            switch state.playbackState {
            case .notRunning, .stopped:
                self.confirmedPrediction = nil
                return false
            default:
                break
            }

            if now.timeIntervalSince(confirmedPrediction.confirmedAt) > confirmationTimeout {
                self.confirmedPrediction = nil
                return false
            }

            if let actualQueueItemID = state.currentQueueItemID ?? state.currentRecord?.queueItemID {
                if actualQueueItemID == confirmedPrediction.key.currentQueueItemID {
                    return true
                }

                if actualQueueItemID == confirmedPrediction.key.nextQueueItemID,
                   state.currentRecord.map({ FormatKey(format: $0.format) == confirmedPrediction.key.nextFormat }) ?? true {
                    if !confirmedPrediction.hasLoggedOutputSkip {
                        debugLog("output-skip", "reason=confirmed next=\(actualQueueItemID)")
                        confirmedPrediction.hasLoggedOutputSkip = true
                        self.confirmedPrediction = confirmedPrediction
                    }
                    return true
                }

                self.confirmedPrediction = nil
            }
        }

        guard let appliedPrediction else {
            return false
        }

        switch state.playbackState {
        case .notRunning, .stopped:
            self.appliedPrediction = nil
            return false
        default:
            break
        }

        if now.timeIntervalSince(appliedPrediction.appliedAt) > confirmationTimeout {
            debugLog("expire", "next=\(appliedPrediction.key.nextQueueItemID) reason=confirmation-timeout")
            self.appliedPrediction = nil
            return false
        }

        if let actualQueueItemID = state.currentQueueItemID ?? state.currentRecord?.queueItemID {
            if actualQueueItemID == appliedPrediction.key.nextQueueItemID {
                return false
            }

            return actualQueueItemID == appliedPrediction.key.currentQueueItemID
        }

        return true
    }

    private func fire(
        key: PredictionKey,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) {
        guard pendingKey == key else {
            return
        }

        pendingWorkItem = nil
        pendingDeadline = nil

        let state = validate()
        switch validatePendingEvent(key: key, state: state) {
        case .skip(let reason):
            debugLog("skipped reason=\(reason.rawValue)")
            if reason == .remainingTimeTooLarge {
                reschedulePendingFromWatchdogState(
                    key: key,
                    state: state,
                    validate: validate,
                    apply: apply
                )
            } else {
                clearPending(logReason: cancellationReason(for: reason))
            }

        case .apply(let remainingTime):
            guard let nextRecord = state.nextRecord else {
                debugLog("skipped reason=missing-next")
                clearPending(logReason: "missing-next")
                return
            }

            debugLog(
                "apply",
                "trigger=timer current=\(key.currentQueueItemID) next=\(nextRecord.queueItemID) remaining=\(formatSeconds(remainingTime)) target=\(formatDescription(nextRecord.format))"
            )
            applyPrediction(
                nextRecord,
                key: key,
                trackIdentity: state.trackIdentity,
                remainingTime: remainingTime,
                apply: apply,
                stopReason: "applied"
            )
        }
    }

    private func reportAppliedPredictionOutcome(for state: PreloadPredictionState) {
        guard let appliedPrediction,
              let actualQueueItemID = state.currentQueueItemID ?? state.currentRecord?.queueItemID else {
            return
        }

        if actualQueueItemID == appliedPrediction.key.nextQueueItemID {
            debugLog("confirm", "next=\(actualQueueItemID)")
            stopWatchdog(logReason: "confirmed")
            endActivity(reason: "confirmed")
            confirmedPrediction = ConfirmedPrediction(key: appliedPrediction.key, confirmedAt: Date())
            self.appliedPrediction = nil
        } else if state.trackIdentity != appliedPrediction.key.trackIdentity {
            debugLog("miss", "predicted=\(appliedPrediction.key.nextQueueItemID) actual=\(actualQueueItemID)")
            stopWatchdog(logReason: "miss")
            endActivity(reason: "miss")
            confirmedPrediction = nil
            self.appliedPrediction = nil
        } else {
            return
        }
    }

    private func validatePendingEvent(
        key: PredictionKey,
        state: PreloadPredictionState
    ) -> PreloadPredictionValidation {
        guard state.playbackState == .playing else {
            return .skip(.notPlaying)
        }

        guard key.trackIdentity == state.trackIdentity else {
            return .skip(.staleTrack)
        }

        guard state.currentQueueItemID == key.currentQueueItemID else {
            return .skip(.staleCurrentRecord)
        }

        guard state.nextRecord?.queueItemID == key.nextQueueItemID else {
            return .skip(.staleNextRecord)
        }

        guard let duration = state.duration,
              duration.isFinite,
              duration > 0 else {
            return .skip(.missingDuration)
        }

        guard let playerPosition = state.playerPosition,
              playerPosition.isFinite,
              playerPosition >= 0 else {
            return .skip(.missingPlayerPosition)
        }

        let remainingTime = duration - playerPosition
        guard remainingTime > 0 else {
            return .skip(.noRemainingTime)
        }

        guard remainingTime <= policy.validationWindow else {
            return .skip(.remainingTimeTooLarge)
        }

        return .apply(remainingTime: remainingTime)
    }

    private func clearPending(logReason: String?) {
        let hadPendingWork = pendingWorkItem != nil
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingKey = nil
        pendingDeadline = nil
        notifyPendingStateChanged()
        stopWatchdog(logReason: logReason)
        endActivity(reason: logReason)

        if hadPendingWork,
           let logReason {
            debugLog("cancelled reason=\(logReason)")
        }
    }

    private func scheduleOneShot(
        key: PredictionKey,
        fireAfter: TimeInterval,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) {
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.fire(
                    key: key,
                    validate: validate,
                    apply: apply
                )
            }
        }
        pendingWorkItem = workItem
        pendingKey = key
        pendingDeadline = Date().addingTimeInterval(fireAfter)
        notifyPendingStateChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireAfter), execute: workItem)
    }

    private func scheduleWatchdog(
        key: PredictionKey,
        state: PreloadPredictionState,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) {
        switch policy.watchdog(
            playbackState: state.playbackState,
            duration: state.duration,
            playerPosition: state.playerPosition,
            currentRecord: state.currentRecord,
            nextRecord: state.nextRecord
        ) {
        case .cancel(let reason):
            stopWatchdog(logReason: cancellationReason(for: reason))
            endActivity(reason: cancellationReason(for: reason))

        case .schedule(let schedule):
            updateActivity(shouldStart: schedule.shouldStartActivity)
            if watchdogKey == key,
               watchdogInterval == schedule.interval,
               watchdogWorkItem != nil {
                return
            }

            let shouldLog = watchdogKey != key
                || watchdogInterval != schedule.interval
                || watchdogWorkItem == nil

            watchdogWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.watchdogTick(
                        key: key,
                        validate: validate,
                        apply: apply
                    )
                }
            }
            watchdogWorkItem = workItem
            watchdogKey = key
            watchdogInterval = schedule.interval
            DispatchQueue.main.asyncAfter(deadline: .now() + schedule.interval, execute: workItem)

            if shouldLog {
                debugLog(
                    "watchdog scheduled interval=\(formatSeconds(schedule.interval)) remaining=\(formatSeconds(schedule.remainingTime))"
                )
            }
        }
    }

    private func watchdogTick(
        key: PredictionKey,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) {
        guard watchdogKey == key else {
            return
        }

        watchdogWorkItem = nil
        let state = validate()
        switch policy.validate(
            expectedTrackIdentity: key.trackIdentity,
            actualTrackIdentity: state.trackIdentity,
            expectedCurrentQueueItemID: key.currentQueueItemID,
            expectedNextQueueItemID: key.nextQueueItemID,
            playbackState: state.playbackState,
            duration: state.duration,
            playerPosition: state.playerPosition,
            currentRecord: state.currentRecord,
            nextRecord: state.nextRecord
        ) {
        case .apply(let remainingTime):
            guard let nextRecord = state.nextRecord else {
                debugLog("skipped reason=missing-next")
                clearPending(logReason: "missing-next")
                return
            }

            debugLog("apply", "trigger=watchdog next=\(nextRecord.queueItemID) remaining=\(formatSeconds(remainingTime)) target=\(formatDescription(nextRecord.format))")
            applyPrediction(
                nextRecord,
                key: key,
                trackIdentity: state.trackIdentity,
                remainingTime: remainingTime,
                apply: apply,
                stopReason: "applied"
            )

        case .skip(let reason):
            if reason == .remainingTimeTooLarge {
                reschedulePendingFromWatchdogState(
                    key: key,
                    state: state,
                    validate: validate,
                    apply: apply
                )
            } else {
                debugLog("skipped reason=\(reason.rawValue)")
                clearPending(logReason: cancellationReason(for: reason))
            }
        }
    }

    private func reschedulePendingFromWatchdogState(
        key: PredictionKey,
        state: PreloadPredictionState,
        validate: @escaping ValidationProvider,
        apply: @escaping PredictionApplier
    ) {
        guard PredictionKey(state: state) == key else {
            clearPending(logReason: "queue-changed")
            return
        }

        switch policy.schedule(
            playbackState: state.playbackState,
            duration: state.duration,
            playerPosition: state.playerPosition,
            currentRecord: state.currentRecord,
            nextRecord: state.nextRecord
        ) {
        case .cancel(let reason):
            clearPending(logReason: cancellationReason(for: state, fallback: reason.rawValue))

        case .schedule(let schedule):
            let deadline = Date().addingTimeInterval(schedule.fireAfter)
            if pendingDeadline.map({ abs(deadline.timeIntervalSince($0)) >= 0.25 }) ?? true {
                scheduleOneShot(
                    key: key,
                    fireAfter: schedule.fireAfter,
                    validate: validate,
                    apply: apply
                )
                debugLog(
                    "watchdog.reschedule",
                    "reason=position-changed fireIn=\(formatSeconds(schedule.fireAfter))"
                )
            }
            scheduleWatchdog(
                key: key,
                state: state,
                validate: validate,
                apply: apply
            )
        }
    }

    @discardableResult
    private func applyPrediction(
        _ nextRecord: AppleMusicPreloadRecord,
        key: PredictionKey,
        trackIdentity: String?,
        remainingTime: TimeInterval,
        apply: PredictionApplier,
        stopReason: String
    ) -> AudioOutputSwitchResult? {
        let result = apply(nextRecord, trackIdentity, key.currentQueueItemID)
        switch result {
        case .applied, .alreadyMatched:
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            pendingKey = nil
            pendingDeadline = nil
            lastMatchingFormatSkipKey = nil
            notifyPendingStateChanged()
            stopWatchdog(logReason: stopReason)
            endActivity(reason: stopReason)
            confirmedPrediction = nil
            appliedPrediction = AppliedPrediction(key: key, appliedAt: Date())
            debugLog(
                "result",
                "action=applied next=\(nextRecord.queueItemID) format=\(formatDescription(nextRecord.format)) remaining=\(formatSeconds(remainingTime))"
            )
        case .failed:
            debugLog("skipped reason=output-switch-failed")
            clearPending(logReason: "output-switch-failed")
        case nil:
            debugLog("skipped reason=no-switch-target")
            clearPending(logReason: "no-switch-target")
        }

        return result
    }

    private func stopWatchdog(logReason: String?) {
        let hadWatchdog = watchdogWorkItem != nil || watchdogKey != nil
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        watchdogKey = nil
        watchdogInterval = nil

        if hadWatchdog,
           let logReason {
            debugLog("watchdog stopped reason=\(logReason)")
        }
    }

    private func updateActivity(shouldStart: Bool) {
        if shouldStart {
            guard activity == nil else {
                return
            }

            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "isLossless prediction end-window"
            )
            debugLog("activity started reason=end-window")
        } else {
            endActivity(reason: "outside-end-window")
        }
    }

    private func endActivity(reason: String?) {
        guard let activity else {
            return
        }

        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        debugLog("activity ended reason=\(reason ?? "unknown")")
    }

    private func cancellationReason(for state: PreloadPredictionState, fallback: String) -> String {
        switch state.playbackState {
        case .paused:
            return "paused"
        case .stopped:
            return "stopped"
        case .notRunning:
            return "not-running"
        default:
            return fallback
        }
    }

    private func cancellationReason(for reason: PreloadPredictionSkipReason) -> String {
        switch reason {
        case .notPlaying:
            return "not-playing"
        case .staleTrack:
            return "track-changed"
        case .staleCurrentRecord, .staleNextRecord:
            return "queue-changed"
        default:
            return reason.rawValue
        }
    }

    private func cancellationReason(replacing oldKey: PredictionKey, with newKey: PredictionKey) -> String {
        if oldKey.trackIdentity != newKey.trackIdentity {
            return "track-changed"
        }

        return "queue-changed"
    }

    private func debugLog(_ message: String) {
        print("[isLossless] prediction: at=\(formatTimestamp(Date())) \(message)")
    }

    private func debugLog(_ action: String, _ fields: String) {
        print("[isLossless] prediction.\(action) at=\(formatTimestamp(Date())) \(fields)")
    }

    private func notifyPendingStateChanged() {
        onPendingStateChanged?(hasPendingPrediction)
    }

    private func formatDescription(_ format: AudioFormat) -> String {
        let sampleRate = format.sampleRate.map { String(Int($0.rounded())) } ?? "unknown"
        let bitDepth = format.bitDepth.map(String.init) ?? "-"
        return "\(sampleRate)/\(bitDepth)"
    }

    private func formatDescription(_ format: AudioFormat?) -> String {
        guard let format else {
            return "unknown/-"
        }

        return formatDescription(format)
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private func formatsMatch(_ lhs: AudioFormat, _ rhs: AudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate && lhs.bitDepth == rhs.bitDepth
    }

    private func isConfirmedTransition(_ key: PredictionKey) -> Bool {
        guard let confirmedPrediction else {
            return false
        }

        return confirmedPrediction.key.currentQueueItemID == key.currentQueueItemID
            && confirmedPrediction.key.nextQueueItemID == key.nextQueueItemID
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private struct PredictionKey: Equatable {
        let trackIdentity: String?
        let currentQueueItemID: Int
        let nextQueueItemID: Int
        let nextFormat: FormatKey

        init?(state: PreloadPredictionState) {
            guard let currentQueueItemID = state.currentQueueItemID ?? state.currentRecord?.queueItemID,
                  let nextRecord = state.nextRecord else {
                return nil
            }

            self.trackIdentity = state.trackIdentity
            self.currentQueueItemID = currentQueueItemID
            self.nextQueueItemID = nextRecord.queueItemID
            self.nextFormat = FormatKey(format: nextRecord.format)
        }
    }

    private struct FormatKey: Equatable {
        let codec: String?
        let sampleRate: Double?
        let bitDepth: Int?

        init(format: AudioFormat) {
            self.codec = format.codec
            self.sampleRate = format.sampleRate
            self.bitDepth = format.bitDepth
        }
    }

    private struct AppliedPrediction {
        let key: PredictionKey
        let appliedAt: Date
    }

    private struct ConfirmedPrediction {
        let key: PredictionKey
        let confirmedAt: Date
        var hasLoggedOutputSkip = false
    }
}
#endif
