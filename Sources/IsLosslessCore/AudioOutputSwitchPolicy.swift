import Foundation

public enum AudioOutputSwitchTarget: Equatable, Hashable, Sendable {
    case nominalSampleRate(Double)
    case physicalFormat(sampleRate: Double, bitDepth: Int)

    public var sampleRate: Double {
        switch self {
        case .nominalSampleRate(let sampleRate):
            return sampleRate
        case .physicalFormat(let sampleRate, _):
            return sampleRate
        }
    }

    public var bitDepth: Int? {
        switch self {
        case .nominalSampleRate:
            return nil
        case .physicalFormat(_, let bitDepth):
            return bitDepth
        }
    }
}

public struct AudioOutputSwitchPolicy: Sendable {
    public init() {}

    public func target(
        status: DetectionStatus,
        format: AudioFormat?,
        appleScriptSampleRate: Double?,
        isPlaybackActive: Bool
    ) -> AudioOutputSwitchTarget? {
        guard status == .detected,
              isPlaybackActive,
              let format else {
            return nil
        }

        if format.codec?.uppercased() == "ALAC" {
            guard let sampleRate = validSampleRate(format.sampleRate) else {
                return nil
            }

            if let bitDepth = format.bitDepth,
               bitDepth > 0 {
                return .physicalFormat(sampleRate: sampleRate, bitDepth: bitDepth)
            }

            return .nominalSampleRate(sampleRate)
        }

        guard let sampleRate = validSampleRate(appleScriptSampleRate) else {
            return nil
        }

        return .nominalSampleRate(sampleRate)
    }

    private func validSampleRate(_ sampleRate: Double?) -> Double? {
        guard let sampleRate,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return nil
        }

        return sampleRate
    }
}
