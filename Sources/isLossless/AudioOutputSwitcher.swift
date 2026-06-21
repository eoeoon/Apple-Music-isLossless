#if os(macOS)
import CoreAudio
import Foundation
import IsLosslessCore

final class AudioOutputSwitcher {
    func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    func apply(_ target: AudioOutputSwitchTarget, to deviceID: AudioDeviceID) -> AudioOutputSwitchResult {
        switch target {
        case .nominalSampleRate(let sampleRate):
            return setNearestNominalSampleRate(sampleRate, for: deviceID)

        case .physicalFormat(let sampleRate, let bitDepth):
            if let candidate = physicalFormatCandidate(
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                for: deviceID
            ) {
                if let currentFormat = streamFormat(
                    for: candidate.streamID,
                    selector: kAudioStreamPropertyPhysicalFormat,
                    scope: candidate.scope
                ),
                   formatsMatch(currentFormat, candidate.format) {
                    return .alreadyMatched("physical format \(formatDescription(candidate.format))")
                }

                let status = setPhysicalFormat(
                    candidate.format,
                    for: candidate.streamID,
                    scope: candidate.scope
                )
                guard status == noErr else {
                    return .failed("physical format \(formatDescription(candidate.format)) status=\(status)")
                }

                return .applied("physical format \(formatDescription(candidate.format))")
            }

            let result = setNearestNominalSampleRate(sampleRate, for: deviceID)
            if case .applied(let description) = result {
                return .applied("\(description); no matching physical format for \(Int(sampleRate))Hz/\(bitDepth)bit")
            }
            return result
        }
    }

    private func setNearestNominalSampleRate(_ sampleRate: Double, for deviceID: AudioDeviceID) -> AudioOutputSwitchResult {
        let nearestSampleRate = nearestNominalSampleRate(to: sampleRate, for: deviceID)

        if let currentSampleRate = nominalSampleRate(for: deviceID),
           sampleRatesMatch(currentSampleRate, nearestSampleRate) {
            return .alreadyMatched("nominal sample rate \(Int(nearestSampleRate))Hz")
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return .failed("nominal sample rate unsupported")
        }

        var newSampleRate = Float64(nearestSampleRate)
        let size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newSampleRate)
        guard status == noErr else {
            return .failed("nominal sample rate \(Int(nearestSampleRate))Hz status=\(status)")
        }

        return .applied("nominal sample rate \(Int(nearestSampleRate))Hz")
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64()
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)

        return status == noErr ? sampleRate : nil
    }

    private func nearestNominalSampleRate(to targetSampleRate: Double, for deviceID: AudioDeviceID) -> Double {
        let ranges = availableNominalSampleRateRanges(for: deviceID)
        guard !ranges.isEmpty else {
            return targetSampleRate
        }

        if ranges.contains(where: { $0.mMinimum <= targetSampleRate && targetSampleRate <= $0.mMaximum }) {
            return targetSampleRate
        }

        let endpoints = ranges.flatMap { range in
            range.mMinimum == range.mMaximum
                ? [range.mMinimum]
                : [range.mMinimum, range.mMaximum]
        }

        return endpoints.min(by: {
            abs($0 - targetSampleRate) < abs($1 - targetSampleRate)
        }) ?? targetSampleRate
    }

    private func availableNominalSampleRateRanges(for deviceID: AudioDeviceID) -> [AudioValueRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeWildcard,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return []
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioValueRange>.size else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        let status = ranges.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(kAudioHardwareBadObjectError)
            }

            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, baseAddress)
        }

        return status == noErr ? ranges : []
    }

    private func physicalFormatCandidate(
        sampleRate: Double,
        bitDepth: Int,
        for deviceID: AudioDeviceID
    ) -> PhysicalFormatCandidate? {
        var nearestBitDepthCandidate: PhysicalFormatCandidate?

        for streamID in outputStreamIDs(for: deviceID) {
            for scope in streamPropertyScopes {
                let formats = availablePhysicalFormats(for: streamID, scope: scope)

                if let exactFormat = formats.first(where: {
                    sampleRatesMatch($0.mSampleRate, sampleRate) && Int($0.mBitsPerChannel) == bitDepth
                }) {
                    return PhysicalFormatCandidate(streamID: streamID, scope: scope, format: exactFormat)
                }

                let sameSampleRateFormats = formats.filter { sampleRatesMatch($0.mSampleRate, sampleRate) }
                if let closestBitDepthFormat = sameSampleRateFormats.min(by: {
                    abs(Int($0.mBitsPerChannel) - bitDepth) < abs(Int($1.mBitsPerChannel) - bitDepth)
                }) {
                    let candidate = PhysicalFormatCandidate(
                        streamID: streamID,
                        scope: scope,
                        format: closestBitDepthFormat
                    )

                    if let currentCandidate = nearestBitDepthCandidate {
                        let currentDistance = abs(Int(currentCandidate.format.mBitsPerChannel) - bitDepth)
                        let newDistance = abs(Int(candidate.format.mBitsPerChannel) - bitDepth)
                        if newDistance < currentDistance {
                            nearestBitDepthCandidate = candidate
                        }
                    } else {
                        nearestBitDepthCandidate = candidate
                    }
                }
            }
        }

        return nearestBitDepthCandidate
    }

    private func outputStreamIDs(for deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioStreamID>.size else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: count)
        let status = streams.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(kAudioHardwareBadObjectError)
            }

            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, baseAddress)
        }

        return status == noErr ? streams : []
    }

    private func availablePhysicalFormats(
        for streamID: AudioStreamID,
        scope: AudioObjectPropertyScope
    ) -> [AudioStreamBasicDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(streamID, &address) else {
            return []
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioStreamRangedDescription>.size else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.size
        var rangedDescriptions = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(),
            count: count
        )
        let status = rangedDescriptions.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(kAudioHardwareBadObjectError)
            }

            return AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, baseAddress)
        }

        return status == noErr ? rangedDescriptions.map(\.mFormat) : []
    }

    private func streamFormat(
        for streamID: AudioStreamID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(streamID, &address) else {
            return nil
        }

        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &description)

        return status == noErr ? description : nil
    }

    private func setPhysicalFormat(
        _ format: AudioStreamBasicDescription,
        for streamID: AudioStreamID,
        scope: AudioObjectPropertyScope
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(streamID, &address) else {
            return OSStatus(kAudioHardwareUnknownPropertyError)
        }

        var mutableFormat = format
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectSetPropertyData(streamID, &address, 0, nil, size, &mutableFormat)
    }

    private func formatsMatch(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        sampleRatesMatch(lhs.mSampleRate, rhs.mSampleRate)
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }

    private func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    private func formatDescription(_ format: AudioStreamBasicDescription) -> String {
        "\(Int(format.mSampleRate))Hz/\(format.mBitsPerChannel)bit"
    }

    private var streamPropertyScopes: [AudioObjectPropertyScope] {
        [
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]
    }
}

enum AudioOutputSwitchResult: Sendable {
    case applied(String)
    case alreadyMatched(String)
    case failed(String)

    var shouldRefreshOutputSnapshot: Bool {
        switch self {
        case .applied, .alreadyMatched:
            return true
        case .failed:
            return false
        }
    }
}

@MainActor
final class AutomaticOutputSwitchCoordinator {
    private let policy = AudioOutputSwitchPolicy()
    private let switcher = AudioOutputSwitcher()
    private var lastAttemptedKey: OutputSwitchKey?

    func applyIfNeeded(for state: AppState) -> AudioOutputSwitchResult? {
        guard let target = policy.target(
            status: state.status,
            format: state.format,
            appleScriptSampleRate: state.appleScriptSampleRate,
            isPlaybackActive: state.trackIdentity != nil
        ) else {
            lastAttemptedKey = nil
            return nil
        }

        guard let deviceID = switcher.defaultOutputDeviceID() else {
            lastAttemptedKey = nil
            debugLog("action=failed source=detected reason=default-output-device-unavailable")
            return .failed("default output device unavailable")
        }

        let key = OutputSwitchKey(
            deviceID: deviceID,
            trackIdentity: state.trackIdentity,
            target: target
        )
        guard key != lastAttemptedKey else {
            return nil
        }

        let result = switcher.apply(target, to: deviceID)
        lastAttemptedKey = key

        switch result {
        case .applied(let description):
            debugLog("action=applied source=detected target=\(targetDescription(target)) detail=\(debugValue(description))")
        case .alreadyMatched(let description):
            debugLog("action=already-matched source=detected target=\(targetDescription(target)) detail=\(debugValue(description))")
        case .failed(let description):
            debugLog("action=failed source=detected target=\(targetDescription(target)) detail=\(debugValue(description))")
        }

        return result
    }

    func applyPrediction(
        format: AudioFormat,
        trackIdentity: String?,
        queueItemID: Int
    ) -> AudioOutputSwitchResult? {
        guard let target = policy.target(
            status: .detected,
            format: format,
            appleScriptSampleRate: format.codec?.uppercased() == "ALAC" ? nil : format.sampleRate,
            isPlaybackActive: true
        ) else {
            debugLog("action=skipped source=prediction q=\(queueItemID) reason=no-switch-target")
            return nil
        }

        guard let deviceID = switcher.defaultOutputDeviceID() else {
            debugLog("action=failed source=prediction q=\(queueItemID) reason=default-output-device-unavailable")
            return .failed("default output device unavailable")
        }

        let key = OutputSwitchKey(
            deviceID: deviceID,
            trackIdentity: "\(trackIdentity ?? "unknown")\u{1F}prediction:\(queueItemID)",
            target: target
        )
        guard key != lastAttemptedKey else {
            return .alreadyMatched("prediction target already attempted")
        }

        let result = switcher.apply(target, to: deviceID)
        lastAttemptedKey = key

        switch result {
        case .applied(let description):
            debugLog("action=applied source=prediction q=\(queueItemID) target=\(targetDescription(target)) detail=\(debugValue(description))")
        case .alreadyMatched(let description):
            debugLog("action=already-matched source=prediction q=\(queueItemID) target=\(targetDescription(target)) detail=\(debugValue(description))")
        case .failed(let description):
            debugLog("action=failed source=prediction q=\(queueItemID) target=\(targetDescription(target)) detail=\(debugValue(description))")
        }

        return result
    }

    private func debugLog(_ message: String) {
        print("[isLossless] output.switch \(message)")
    }

    private func targetDescription(_ target: AudioOutputSwitchTarget) -> String {
        switch target {
        case .nominalSampleRate(let sampleRate):
            return "nominal:\(Int(sampleRate.rounded()))"
        case .physicalFormat(let sampleRate, let bitDepth):
            return "physical:\(Int(sampleRate.rounded()))/\(bitDepth)"
        }
    }

    private func debugValue(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private struct OutputSwitchKey: Equatable {
        let deviceID: AudioDeviceID
        let trackIdentity: String?
        let target: AudioOutputSwitchTarget
    }
}

private struct PhysicalFormatCandidate {
    let streamID: AudioStreamID
    let scope: AudioObjectPropertyScope
    let format: AudioStreamBasicDescription
}
#endif
