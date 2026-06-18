import Foundation

public struct AppleMusicLogParser: Sendable {
    public init() {}

    public func parse(_ message: String) -> AudioFormat? {
        if let playbackFormat = parsePlaybackFormat(message) {
            return playbackFormat
        }

        guard isSourceFormatMessage(message) else {
            return nil
        }

        let codec = parseCodec(in: message)
        let bitDepth = parseBitDepth(in: message)
        let sampleRate = parseSampleRate(in: message)
        let format = AudioFormat(codec: codec, bitDepth: bitDepth, sampleRate: sampleRate)
        return format.isEmpty ? nil : format
    }

    public func parsePlaybackFormat(_ message: String) -> AudioFormat? {
        let lowercasedMessage = message.lowercased()

        guard lowercasedMessage.contains("audio format changed to pbaudioformat.") else {
            return nil
        }

        if lowercasedMessage.contains("lossless") {
            return AudioFormat(codec: "ALAC")
        }

        if lowercasedMessage.contains("pbaudioformat.other") {
            return AudioFormat(codec: "AAC")
        }

        return nil
    }

    private func parseCodec(in message: String) -> String? {
        let lowercasedMessage = message.lowercased()

        if lowercasedMessage.contains("applelossless")
            || lowercasedMessage.contains("alac")
            || lowercasedMessage.contains("lossless")
            || lowercasedMessage.contains("rendition lossless") {
            return "ALAC"
        }

        if lowercasedMessage.contains("aac") {
            return "AAC"
        }

        return nil
    }

    private func isSourceFormatMessage(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("input format")
            || lowercasedMessage.contains("source format")
            || lowercasedMessage.contains("bit source")
            || lowercasedMessage.contains("rendition lossless")
            || lowercasedMessage.contains("audio-alac")
            || lowercasedMessage.contains("[alac]")
            || lowercasedMessage.contains("_lossless.m3u8")
            || lowercasedMessage.contains("pbaudioformat.lossless")
            || lowercasedMessage.contains("activeformat:")
    }

    private func parseBitDepth(in message: String) -> Int? {
        let patterns = [
            #"(\d{2})\s*-?\s*bit\s+source"#,
            #"(\d{2})\s*-?\s*bit"#,
            #"BitDepth\D+(\d{2})"#,
            #"audio-alac-[^\s\]]*-\d+-(\d{2})"#
        ]

        return firstIntegerMatch(in: message, patterns: patterns)
    }

    private func parseSampleRate(in message: String) -> Double? {
        let patterns = [
            #"(\d+(?:\.\d+)?)\s*Hz"#,
            #"(\d+(?:\.\d+)?)\s*kHz"#,
            #"SampleRate\D+(\d+(?:\.\d+)?)"#,
            #"audio-alac-[^\s\]]*-(\d+)-\d{2}"#
        ]

        guard let sampleRate = firstDoubleMatch(in: message, patterns: patterns) else {
            return nil
        }

        return sampleRate < 1_000 ? sampleRate * 1_000 : sampleRate
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
