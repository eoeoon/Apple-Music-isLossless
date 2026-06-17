import Foundation

public struct MenuBarTitleFormatter: Sendable {
    public init() {}

    public func title(for format: AudioFormat?, status: DetectionStatus) -> String {
        if let format, !format.isEmpty {
            return detectedTitle(for: format)
        }

        switch status {
        case .detected:
            return "—"
        case .detecting:
            return "—"
        default:
            return "isLossless"
        }
    }

    public func detectedTitle(for format: AudioFormat) -> String {
        if format.codec == "AAC" {
            let parts = [format.codec, format.bitRate.map { "\($0)kbps" }].compactMap { $0 }
            return parts.isEmpty ? "—" : parts.joined(separator: " ")
        }

        let bitRateText = format.bitRate.map { "\($0)kbps" }
        let bitDepthText = format.bitDepth.map { "\($0)비트" }
        let sampleRateText = format.sampleRate.map(formatSampleRate)
        let parts = [format.codec, bitDepthText, bitRateText, sampleRateText].compactMap { $0 }

        return parts.isEmpty ? "—" : parts.joined(separator: " ")
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
