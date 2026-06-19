import Foundation

public struct AppleMusicQueueItemBegin: Equatable, Sendable {
    public let title: String
    public let duration: Double
    public let queueItemID: Int
    public let queueSectionID: Int?

    public init(title: String, duration: Double, queueItemID: Int, queueSectionID: Int? = nil) {
        self.title = title
        self.duration = duration
        self.queueItemID = queueItemID
        self.queueSectionID = queueSectionID
    }
}

public struct AppleMusicAudioFormatChange: Equatable, Sendable {
    public let queueItemID: Int
    public let queueSectionID: Int?
    public let groupID: String?
    public let format: AudioFormat?

    public init(queueItemID: Int, queueSectionID: Int? = nil, groupID: String? = nil, format: AudioFormat? = nil) {
        self.queueItemID = queueItemID
        self.queueSectionID = queueSectionID
        self.groupID = groupID
        self.format = format
    }
}

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

    public func parseQueueItemBegin(_ message: String) -> AppleMusicQueueItemBegin? {
        guard message.localizedCaseInsensitiveContains("item-begin"),
              let rawTitle = firstMatch(in: message, pattern: #""item-title"\s*=\s*"([^"]*)""#),
              let duration = firstDoubleMatch(
                in: message,
                patterns: [#""item-duration"\s*=\s*"?(\d+(?:\.\d+)?)"?"#]
              ),
              let queueItemID = firstIntegerMatch(
                in: message,
                patterns: [#""queue-item-id"\s*=\s*(\d+)"#]
              ) else {
            return nil
        }

        let queueSectionID = firstIntegerMatch(
            in: message,
            patterns: [#""queue-section-id"\s*=\s*(\d+)"#]
        )

        return AppleMusicQueueItemBegin(
            title: decodeMusicLogString(rawTitle),
            duration: duration,
            queueItemID: queueItemID,
            queueSectionID: queueSectionID
        )
    }

    public func parseAudioFormatChanged(_ message: String) -> AppleMusicAudioFormatChange? {
        guard isAudioFormatChangedPayload(message),
              let queueItemID = firstIntegerMatch(
                in: message,
                patterns: [#""queue-item-id"\s*=\s*(\d+)"#]
              ) else {
            return nil
        }

        let queueSectionID = firstIntegerMatch(
            in: message,
            patterns: [#""queue-section-id"\s*=\s*(\d+)"#]
        )
        let groupID = firstMatch(in: message, pattern: #"\bgrp\s*=\s*"([^"]+)""#)
        let format = format(fromAudioGroup: groupID, message: message)

        return AppleMusicAudioFormatChange(
            queueItemID: queueItemID,
            queueSectionID: queueSectionID,
            groupID: groupID,
            format: format
        )
    }

    private func isAudioFormatChangedPayload(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("audio-format-changed")
            || lowercasedMessage.contains("item-audio-format-metadata")
            || lowercasedMessage.contains("\"active-format\"")
            || lowercasedMessage.contains("grp = \"audio-alac")
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

    private func format(fromAudioGroup groupID: String?, message: String) -> AudioFormat? {
        guard let groupID,
              groupID.localizedCaseInsensitiveContains("audio-alac") else {
            return nil
        }

        let bitDepth = firstIntegerMatch(
            in: message,
            patterns: [
                #"\bbd\s*=\s*(\d+)"#,
                #"audio-alac-[^\s\]]*-\d+-(\d{2})"#
            ]
        )
        let sampleRate = firstDoubleMatch(
            in: message,
            patterns: [
                #"\bsr\s*=\s*(\d+(?:\.\d+)?)"#,
                #"audio-alac-[^\s\]]*-(\d+)-\d{2}"#
            ]
        )

        return AudioFormat(codec: "ALAC", bitDepth: bitDepth, sampleRate: sampleRate)
    }

    private func decodeMusicLogString(_ value: String) -> String {
        var decoded = ""
        var index = value.startIndex

        while index < value.endIndex {
            if value[index] == "\\" {
                if let scalar = unicodeScalar(afterOctalBackslashAt: index, in: value) {
                    decoded.append(Character(scalar.value))
                    index = scalar.endIndex
                    continue
                }

                if let scalar = unicodeScalar(afterBackslashAt: index, in: value) {
                    decoded.append(Character(scalar.value))
                    index = scalar.endIndex
                    continue
                }

                if let octal = octalScalar(at: index, in: value) {
                    decoded.append(Character(octal.value))
                    index = octal.endIndex
                    continue
                }
            }

            decoded.append(value[index])
            index = value.index(after: index)
        }

        return decoded
    }

    private func unicodeScalar(afterOctalBackslashAt index: String.Index, in value: String) -> (value: UnicodeScalar, endIndex: String.Index)? {
        guard value[index...].hasPrefix(#"\134U"#) else {
            return nil
        }

        let hexStart = value.index(index, offsetBy: 5)
        return unicodeScalar(fromHexAt: hexStart, in: value)
    }

    private func unicodeScalar(afterBackslashAt index: String.Index, in value: String) -> (value: UnicodeScalar, endIndex: String.Index)? {
        guard value[index...].hasPrefix(#"\U"#) else {
            return nil
        }

        let hexStart = value.index(index, offsetBy: 2)
        return unicodeScalar(fromHexAt: hexStart, in: value)
    }

    private func unicodeScalar(fromHexAt index: String.Index, in value: String) -> (value: UnicodeScalar, endIndex: String.Index)? {
        let hexEnd = value.index(index, offsetBy: 4, limitedBy: value.endIndex) ?? value.endIndex
        guard value.distance(from: index, to: hexEnd) == 4 else {
            return nil
        }

        let hex = String(value[index..<hexEnd])
        guard let scalarValue = UInt32(hex, radix: 16),
              let scalar = UnicodeScalar(scalarValue) else {
            return nil
        }

        return (scalar, hexEnd)
    }

    private func octalScalar(at index: String.Index, in value: String) -> (value: UnicodeScalar, endIndex: String.Index)? {
        guard value[index] == "\\" else {
            return nil
        }

        let digitsStart = value.index(after: index)
        let digitsEnd = value.index(digitsStart, offsetBy: 3, limitedBy: value.endIndex) ?? value.endIndex
        guard value.distance(from: digitsStart, to: digitsEnd) == 3 else {
            return nil
        }

        let digits = String(value[digitsStart..<digitsEnd])
        guard digits.allSatisfy({ ("0"..."7").contains($0) }),
              let scalarValue = UInt32(digits, radix: 8),
              let scalar = UnicodeScalar(scalarValue) else {
            return nil
        }

        return (scalar, digitsEnd)
    }
}
