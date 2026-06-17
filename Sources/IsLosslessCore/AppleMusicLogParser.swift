import Foundation

public struct AppleMusicLogParser: Sendable {
    public init() {}

    public func parse(_ message: String) -> AudioFormat? {
        let bitDepth = parseBitDepth(in: message)
        let sampleRate = parseSampleRate(in: message)
        let format = AudioFormat(bitDepth: bitDepth, sampleRate: sampleRate)
        return format.isEmpty ? nil : format
    }

    private func parseBitDepth(in message: String) -> Int? {
        let patterns = [
            #"(\d{2})\s*-?\s*bit\s+source"#,
            #"(\d{2})\s*-?\s*bit"#,
            #"bitDepth\D+(\d{2})"#,
            #"sdBitDepth\D+(\d{2})"#
        ]

        return firstIntegerMatch(in: message, patterns: patterns)
    }

    private func parseSampleRate(in message: String) -> Double? {
        let patterns = [
            #"(\d+(?:\.\d+)?)\s*Hz"#,
            #"sampleRate\D+(\d+(?:\.\d+)?)"#,
            #"asbdSampleRate\D+(\d+(?:\.\d+)?)"#
        ]

        return firstDoubleMatch(in: message, patterns: patterns)
    }

    private func firstIntegerMatch(in message: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            if let value = firstMatch(in: message, pattern: pattern).flatMap(Int.init) {
                return value
            }
        }
        return nil
    }

    private func firstDoubleMatch(in message: String, patterns: [String]) -> Double? {
        for pattern in patterns {
            if let value = firstMatch(in: message, pattern: pattern).flatMap(Double.init) {
                return value
            }
        }
        return nil
    }

    private func firstMatch(in message: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: message) else {
            return nil
        }

        return String(message[valueRange])
    }
}
