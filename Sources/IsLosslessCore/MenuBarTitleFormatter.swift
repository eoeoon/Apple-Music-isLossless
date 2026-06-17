import Foundation

public struct MenuBarTitleFormatter: Sendable {
    public init() {}

    public func title(for format: AudioFormat?, status: DetectionStatus) -> String {
        switch status {
        case .detected:
            guard let format, !format.isEmpty else { return "—" }
            return detectedTitle(for: format)
        case .detecting:
            return "확인 중"
        default:
            return "—"
        }
    }

    public func detectedTitle(for format: AudioFormat) -> String {
        let sampleRateText = format.sampleRate.map(formatSampleRate)

        switch (format.bitDepth, sampleRateText) {
        case let (.some(bitDepth), .some(sampleRateText)):
            return "\(bitDepth)비트 \(sampleRateText)"
        case let (.none, .some(sampleRateText)):
            return sampleRateText
        case let (.some(bitDepth), .none):
            return "\(bitDepth)비트"
        case (.none, .none):
            return "—"
        }
    }

    public func formatSampleRate(_ hertz: Double) -> String {
        let kilohertz = hertz >= 1_000 ? hertz / 1_000 : hertz
        let rounded = (kilohertz * 10).rounded() / 10

        if rounded.rounded() == rounded {
            return "\(Int(rounded))kHz"
        }

        return String(format: "%.1fkHz", rounded)
    }
}
