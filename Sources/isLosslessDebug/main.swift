#if os(macOS)
import Foundation
import IsLosslessCore
import OSLog

@main
struct IsLosslessDebug {
    static func main() {
        let options = DebugOptions(arguments: CommandLine.arguments)
        let inspector = AppleMusicDebugInspector(lookback: options.lookback)

        for index in 0..<options.samples {
            if options.samples > 1 {
                print("=== Sample \(index + 1)/\(options.samples) ===")
            }

            inspector.printSnapshot()

            if index + 1 < options.samples {
                Thread.sleep(forTimeInterval: options.interval)
                print("")
            }
        }
    }
}

struct DebugOptions {
    var lookback: TimeInterval = 30
    var interval: TimeInterval = 2
    var samples: Int = 1

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--last":
                if let value = arguments.value(after: &index).flatMap(Double.init) {
                    lookback = value
                }
            case "--interval":
                if let value = arguments.value(after: &index).flatMap(Double.init) {
                    interval = value
                }
            case "--samples":
                if let value = arguments.value(after: &index).flatMap(Int.init) {
                    samples = max(1, value)
                }
            case "--help", "-h":
                print("""
                Usage: swift run isLosslessDebug [--last seconds] [--samples count] [--interval seconds]

                Prints the short set of AppleScript and log values that isLossless uses.
                """)
                exit(0)
            default:
                break
            }
            index += 1
        }
    }
}

final class AppleMusicDebugInspector {
    private let lookback: TimeInterval
    private let parser = AppleMusicLogParser()

    init(lookback: TimeInterval) {
        self.lookback = lookback
    }

    func printSnapshot() {
        let track = AppleScriptTrackReader().currentTrack()
        let logs = parsedLogs()
        let selectedLog = selectedFormat(from: logs)
        let scriptFormat = track.format
        let resolvedFormat = resolvedFormat(scriptFormat: scriptFormat, logFormat: selectedLog?.format)

        print("Track: \(track.title ?? "-") - \(track.artist ?? "-")")
        print("AppleScript: \(format(scriptFormat) ?? "-") | status=\(track.playerState ?? "-") | kind=\(track.kind ?? "-")")
        print("Log scan: \(format(selectedLog?.format) ?? "-") | source=\(selectedLog?.reason ?? "-") | parsed=\(logs.count) | lookback=\(Int(lookback))s")
        print("Selected raw: \(selectedLog?.oneLine ?? "-")")
        print("isLossless uses: \(format(resolvedFormat) ?? "-")")

        if let error = track.error {
            print("AppleScript error: \(error.oneLine)")
        }
    }

    private func parsedLogs() -> [ParsedLog] {
        let store: OSLogStore
        do {
            store = try OSLogStore.local()
        } catch {
            return []
        }

        let position = store.position(date: Date().addingTimeInterval(-lookback))
        let predicate = NSPredicate(
            format: """
            process == %@ AND (eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@)
            """,
            "Music",
            "activeFormat:",
            "input format",
            "source format",
            "bit source",
            "rendition lossless",
            "audio-alac",
            "_lossless.m3u8",
            "PBAudioFormat.lossless"
        )
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return []
        }

        var logs: [ParsedLog] = []
        for case let entry as OSLogEntryLog in entries {
            guard entry.process == "Music",
                  let format = parser.parse(entry.composedMessage) else {
                continue
            }

            logs.append(
                ParsedLog(
                    date: entry.date,
                    reason: reason(for: entry.composedMessage),
                    message: entry.composedMessage,
                    format: format
                )
            )
        }

        return logs.sorted { $0.date > $1.date }
    }

    private func selectedFormat(from logs: [ParsedLog]) -> ParsedLog? {
        if let activeFormat = logs.first(where: { $0.message.localizedCaseInsensitiveContains("activeFormat:") }) {
            return activeFormat
        }

        return logs.max { $0.format.specificityScore < $1.format.specificityScore }
    }

    private func resolvedFormat(scriptFormat: AudioFormat?, logFormat: AudioFormat?) -> AudioFormat? {
        guard let logFormat else {
            return scriptFormat
        }

        guard let scriptFormat else {
            return logFormat
        }

        let codec = scriptFormat.codec == "ALAC" || logFormat.codec == "ALAC"
            ? "ALAC"
            : (logFormat.codec ?? scriptFormat.codec)

        return AudioFormat(
            codec: codec,
            bitDepth: logFormat.bitDepth ?? scriptFormat.bitDepth,
            bitRate: codec == "ALAC" ? nil : (logFormat.bitRate ?? scriptFormat.bitRate),
            sampleRate: logFormat.sampleRate ?? scriptFormat.sampleRate
        )
    }

    private func reason(for message: String) -> String {
        let lowercased = message.lowercased()

        if lowercased.contains("activeformat:") {
            return "activeFormat"
        }
        if lowercased.contains("audio-alac") {
            return "HLS ALAC alternate"
        }
        if lowercased.contains("input format") {
            return "decoder input format"
        }
        if lowercased.contains("rendition lossless") || lowercased.contains("samplerate") {
            return "playback report"
        }
        if lowercased.contains("pbaudioformat.lossless") {
            return "player UI lossless state"
        }

        return "parsed source-format candidate"
    }
}

struct ParsedLog {
    let date: Date
    let reason: String
    let message: String
    let format: AudioFormat

    var oneLine: String {
        "\(date.formatted(date: .omitted, time: .standard)) \(message.oneLine)"
    }
}

struct AppleScriptTrackReader {
    func currentTrack() -> AppleScriptTrack {
        let script = """
        tell application "Music"
            set fieldDelimiter to ASCII character 31
            set playerStateText to player state as text
            if playerStateText is "stopped" then
                return playerStateText
            end if
            set currentTrack to current track
            set trackID to ""
            set trackName to ""
            set artistName to ""
            set trackKind to ""
            set trackBitRate to ""
            set trackSampleRate to ""
            set trackPosition to ""
            try
                set trackID to persistent ID of currentTrack as text
            end try
            try
                set trackName to name of currentTrack as text
            end try
            try
                set artistName to artist of currentTrack as text
            end try
            try
                set trackKind to kind of currentTrack as text
            end try
            try
                set trackBitRate to bit rate of currentTrack as text
            end try
            try
                set trackSampleRate to sample rate of currentTrack as text
            end try
            try
                set trackPosition to player position as text
            end try
            return playerStateText & fieldDelimiter & trackID & fieldDelimiter & trackName & fieldDelimiter & artistName & fieldDelimiter & trackKind & fieldDelimiter & trackBitRate & fieldDelimiter & trackSampleRate & fieldDelimiter & trackPosition
        end tell
        """

        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let value = descriptor.stringValue else {
            return AppleScriptTrack(playerState: nil, error: error?.description)
        }

        let parts = value.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard parts.first != "stopped" else {
            return AppleScriptTrack(playerState: "stopped")
        }

        return AppleScriptTrack(
            playerState: parts.nonEmptyValue(at: 0),
            persistentID: parts.nonEmptyValue(at: 1),
            title: parts.nonEmptyValue(at: 2),
            artist: parts.nonEmptyValue(at: 3),
            kind: parts.nonEmptyValue(at: 4),
            bitRate: parts.nonEmptyValue(at: 5).flatMap(Int.init),
            sampleRate: parts.nonEmptyValue(at: 6).flatMap(Double.init),
            playerPosition: parts.nonEmptyValue(at: 7).flatMap(Double.init)
        )
    }
}

struct AppleScriptTrack {
    var playerState: String?
    var persistentID: String?
    var title: String?
    var artist: String?
    var kind: String?
    var bitRate: Int?
    var sampleRate: Double?
    var playerPosition: Double?
    var error: String?

    var format: AudioFormat? {
        let format = AudioFormat(
            codec: codec,
            bitRate: bitRate,
            sampleRate: sampleRate
        )
        return format.isEmpty ? nil : format
    }

    private var codec: String? {
        guard let kind else {
            return nil
        }

        let lowercasedKind = kind.lowercased()
        if lowercasedKind.contains("aac") {
            return "AAC"
        }
        if lowercasedKind.contains("lossless") || lowercasedKind.contains("alac") {
            return "ALAC"
        }

        return nil
    }
}

private extension AudioFormat {
    var specificityScore: Int {
        var score = 0
        if codec != nil { score += 1 }
        if sampleRate != nil { score += 2 }
        if bitDepth != nil { score += 4 }
        return score
    }
}

private extension Array where Element == String {
    func value(after index: inout Int) -> String? {
        let nextIndex = index + 1
        guard indices.contains(nextIndex) else {
            return nil
        }
        index = nextIndex
        return self[nextIndex]
    }

    func nonEmptyValue(at index: Int) -> String? {
        guard indices.contains(index), !self[index].isEmpty else {
            return nil
        }

        return self[index]
    }
}

private extension String {
    var oneLine: String {
        components(separatedBy: .newlines).joined(separator: " ")
    }

    func truncated(to maxLength: Int) -> String {
        guard count > maxLength else {
            return self
        }

        return String(prefix(maxLength)) + "..."
    }
}

private func format(_ format: AudioFormat?) -> String? {
    guard let format else {
        return nil
    }

    let text = [
        format.codec,
        format.bitDepth.map { "\($0)-bit" },
        format.sampleRate.map(formatHertz),
        format.bitRate.map { "\($0)kbps" }
    ]
    .compactMap { $0 }
    .joined(separator: " ")

    return text.isEmpty ? nil : text
}

private func formatHertz(_ hertz: Double) -> String {
    let kilohertz = hertz >= 1_000 ? hertz / 1_000 : hertz
    let rounded = (kilohertz * 10).rounded() / 10

    if rounded.rounded() == rounded {
        return "\(Int(rounded))kHz"
    }

    return String(format: "%.1fkHz", rounded)
}

#else
@main
struct IsLosslessDebug {
    static func main() {
        print("isLosslessDebug is available on macOS only.")
    }
}
#endif
