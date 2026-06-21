import Foundation

public enum MenuBarStatusMarker: Equatable, Sendable {
    case none
    case filled(MarkerColor)
    case outline(MarkerColor)
}

public enum MarkerColor: Equatable, Sendable {
    case green
    case yellow
    case red
}

public struct MenuBarStatusMarkerPolicy: Sendable {
    public init() {}

    public static func marker(
        detectionStatus: DetectionStatus,
        currentFormat: AudioFormat?,
        outputSampleRate: Double?,
        outputBitDepth: Int?,
        isTransitioning: Bool
    ) -> MenuBarStatusMarker {
        if isTransitioning {
            return .none
        }

        if detectionStatus == .failed {
            return .filled(.red)
        }

        guard let currentSampleRate = validSampleRate(currentFormat?.sampleRate),
              let outputSampleRate = validSampleRate(outputSampleRate) else {
            return .none
        }

        if sampleRatesMatch(currentSampleRate, outputSampleRate) {
            guard let currentBitDepth = validBitDepth(currentFormat?.bitDepth),
                  let outputBitDepth = validBitDepth(outputBitDepth) else {
                return .filled(.green)
            }

            return currentBitDepth == outputBitDepth ? .filled(.green) : .outline(.green)
        }

        return currentSampleRate > outputSampleRate ? .filled(.yellow) : .outline(.green)
    }

    private static func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    private static func validSampleRate(_ sampleRate: Double?) -> Double? {
        guard let sampleRate,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return nil
        }

        return sampleRate
    }

    private static func validBitDepth(_ bitDepth: Int?) -> Int? {
        guard let bitDepth,
              bitDepth > 0 else {
            return nil
        }

        return bitDepth
    }
}
