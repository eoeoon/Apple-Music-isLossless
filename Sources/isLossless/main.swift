#if os(macOS)
import AppKit
import CoreAudio
import Foundation
import IsLosslessCore
import OSLog

@main
enum IsLosslessMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = IsLosslessApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class IsLosslessApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let formatter = MenuBarTitleFormatter()
    private let monitor = AppleMusicMonitor()
    private var state = AppState(status: .detecting)
    private var menuLabels: [String: NSTextField] = [:]
    private var isMenuOpen = false
    private var previousTrackIdentity: String?
    private var followUpRefreshWorkItems: [DispatchWorkItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        updateMenuBarTitle()
        observeAppleMusicChanges()
        refresh()
        print("isLossless is running. Look for the waveform icon in the macOS menu bar.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func refresh() {
        refresh(forceLogScan: false)
    }

    @objc private func manualRefresh() {
        refresh(forceLogScan: true)
    }

    private func refresh(forceLogScan: Bool) {
        let oldLayoutIdentity = state.menuLayoutIdentity
        state = monitor.snapshot(forceLogScan: forceLogScan)
        updateMenuBarTitle()
        if isMenuOpen {
            if oldLayoutIdentity == state.menuLayoutIdentity {
                updateMenuLabels()
            }
        } else {
            populateMenu(menu)
        }
        scheduleFollowUpRefreshesIfNeeded()
    }

    private func observeAppleMusicChanges() {
        let notificationCenter = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            notificationCenter.addObserver(
                self,
                selector: #selector(playerInfoDidChange(_:)),
                name: NSNotification.Name(name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
    }

    @objc private func playerInfoDidChange(_ notification: Notification) {
        refresh(forceLogScan: false)
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem.button else {
            print("isLossless could not create a menu bar button.")
            return
        }

        button.image = nil
        button.title = formatter.title(for: state.format, status: state.status)
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = state.accessibilityDescription
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        state = monitor.snapshot(forceLogScan: false)
        updateMenuBarTitle()
        populateMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menuLabels.removeAll()
        menu.addItem(spacerItem(height: 8))

        if let title = state.trackTitle, !title.isEmpty {
            menu.addItem(informationalItem(title, key: "title"))
        }

        if let artist = state.artistName, !artist.isEmpty {
            menu.addItem(informationalItem(artist, key: "artist", secondary: true))
        }

        if state.trackTitle != nil || state.artistName != nil {
            menu.addItem(.separator())
        }

        menu.addItem(informationalItem("출력"))
        let outputText = [state.outputDeviceName, state.outputSampleRate.map(formatter.formatSampleRate)]
            .compactMap { $0 }
            .joined(separator: " · ")
        menu.addItem(informationalItem(outputText.isEmpty ? "—" : outputText, key: "output", secondary: true))
        menu.addItem(.separator())
        menu.addItem(informationalItem("상태"))
        menu.addItem(informationalItem(state.statusText, key: "status", secondary: true))
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "새로 고침", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    private func updateMenuLabels() {
        menuLabels["title"]?.stringValue = state.trackTitle ?? ""
        menuLabels["artist"]?.stringValue = state.artistName ?? ""
        let outputText = [state.outputDeviceName, state.outputSampleRate.map(formatter.formatSampleRate)]
            .compactMap { $0 }
            .joined(separator: " · ")
        menuLabels["output"]?.stringValue = outputText.isEmpty ? "—" : outputText
        menuLabels["status"]?.stringValue = state.statusText
    }

    private func scheduleFollowUpRefreshesIfNeeded() {
        guard state.playbackStatus == .playing else {
            return
        }

        guard state.trackIdentity != previousTrackIdentity else {
            return
        }

        previousTrackIdentity = state.trackIdentity
        followUpRefreshWorkItems.forEach { $0.cancel() }
        followUpRefreshWorkItems.removeAll()

        for delay in [2.0, 4.0, 6.0, 8.0] {
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.refresh(forceLogScan: false)
                }
            }
            followUpRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func informationalItem(_ title: String, key: String? = nil, emphasized: Bool = false, secondary: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: emphasized ? .semibold : .regular)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.frame = NSRect(x: 16, y: 0, width: 280, height: 24)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 312, height: 24))
        container.addSubview(label)
        item.view = container
        if let key {
            menuLabels[key] = label
        }
        return item
    }

    private func spacerItem(height: CGFloat) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: 312, height: height))
        return item
    }
}

struct AppState: Sendable {
    var status: DetectionStatus = .idle
    var playbackStatus: PlaybackStatus = .unknown
    var format: AudioFormat?
    var trackIdentity: String?
    var trackTitle: String?
    var artistName: String?
    var outputDeviceName: String?
    var outputSampleRate: Double?

    var menuLayoutIdentity: String {
        [
            trackTitle == nil ? "no-title" : "title",
            artistName == nil ? "no-artist" : "artist"
        ].joined(separator: "|")
    }

    var statusText: String {
        switch playbackStatus {
        case .playing: "재생 중"
        case .paused: "일시 정지"
        case .stopped: "재생 중인 음악이 없습니다"
        case .notRunning: "Apple Music이 실행 중이 아닙니다"
        case .unknown: "확인 중"
        }
    }

    var accessibilityDescription: String {
        switch status {
        case .detected:
            let title = MenuBarTitleFormatter().title(for: format, status: status)
            return "현재 Apple Music 포맷: \(title)"
        default:
            return statusText
        }
    }
}

enum PlaybackStatus: Sendable {
    case unknown
    case notRunning
    case stopped
    case paused
    case playing
}

final class AppleMusicMonitor {
    private let parser = AppleMusicLogParser()
    private let outputReader = AudioOutputReader()
    private var cachedFormat: AudioFormat?
    private var currentTrackIdentity: String?
    private var currentTrackStartedAt: Date?
    private var logScanDeadline: Date?
    private var nextLogScanAt: Date?

    func snapshot(forceLogScan: Bool = false) -> AppState {
        guard isAppleMusicRunning else {
            cachedFormat = nil
            currentTrackIdentity = nil
            currentTrackStartedAt = nil
            logScanDeadline = nil
            nextLogScanAt = nil
            return AppState(status: .appleMusicNotRunning, playbackStatus: .notRunning)
        }

        let track = currentTrack()
        if track.isStopped {
            cachedFormat = nil
            currentTrackIdentity = nil
            currentTrackStartedAt = nil
            logScanDeadline = nil
            nextLogScanAt = nil
        } else if track.identity != currentTrackIdentity {
            cachedFormat = nil
            currentTrackIdentity = track.identity
            currentTrackStartedAt = track.startedAt ?? Date().addingTimeInterval(-120)
            logScanDeadline = Date().addingTimeInterval(8)
            nextLogScanAt = nil
        } else if cachedFormat != nil || !isLogScanActive {
            cachedFormat = cachedFormat?.preservingBitDepth(from: track.format) ?? track.format
        }

        if forceLogScan {
            currentTrackStartedAt = Date().addingTimeInterval(-8)
            logScanDeadline = Date().addingTimeInterval(10)
            nextLogScanAt = nil
        }

        if shouldScanLogs, let latestFormat = latestFormatFromLogs(since: currentTrackStartedAt) {
            cachedFormat = track.format?.merging(latestFormat) ?? latestFormat
        } else if !track.isStopped, cachedFormat == nil, !isLogScanActive {
            cachedFormat = track.format
        }

        let format = cachedFormat
        let output = outputReader.currentOutput()
        var state = AppState(
            status: format == nil ? .detecting : .detected,
            playbackStatus: track.playbackStatus,
            format: format,
            trackIdentity: track.identity,
            trackTitle: track.title,
            artistName: track.artist,
            outputDeviceName: output.name,
            outputSampleRate: output.sampleRate
        )

        if track.isStopped {
            state.status = .notPlaying
            state.format = nil
        } else if track.isPaused {
            state.status = .paused
        }

        return state
    }

    private var isAppleMusicRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    private var shouldScanLogs: Bool {
        guard let logScanDeadline, Date() <= logScanDeadline else {
            return false
        }

        if let nextLogScanAt, Date() < nextLogScanAt {
            return false
        }

        nextLogScanAt = Date().addingTimeInterval(2)
        return true
    }

    private var isLogScanActive: Bool {
        guard let logScanDeadline else {
            return false
        }

        return Date() <= logScanDeadline
    }

    private func currentTrack() -> TrackSnapshot {
        let script = """
        tell application "Music"
            set fieldDelimiter to ASCII character 31
            set playerState to player state as text
            if player state is stopped then
                return playerState
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
            return playerState & fieldDelimiter & trackID & fieldDelimiter & trackName & fieldDelimiter & artistName & fieldDelimiter & trackKind & fieldDelimiter & trackBitRate & fieldDelimiter & trackSampleRate & fieldDelimiter & trackPosition
        end tell
        """

        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let value = descriptor.stringValue else {
            return TrackSnapshot(playerState: nil)
        }

        let parts = value.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard parts.first != "stopped" else {
            return TrackSnapshot(playerState: "stopped")
        }

        return TrackSnapshot(
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

    private func latestFormatFromLogs(since date: Date?) -> AudioFormat? {
        let store: OSLogStore
        do {
            store = try OSLogStore.local()
        } catch {
            return nil
        }

        let position = store.position(date: (date ?? Date().addingTimeInterval(-12)).addingTimeInterval(-1))
        guard let entries = try? store.getEntries(at: position) else {
            return nil
        }

        let logMessages = entries
            .compactMap { $0 as? OSLogEntryLog }
            .reversed()
            .map(\.composedMessage)

        if let activeFormat = logMessages
            .filter({ $0.localizedCaseInsensitiveContains("activeFormat:") })
            .compactMap({ self.parser.parse($0) })
            .first {
            return activeFormat
        }

        let parsedFormats = logMessages
            .compactMap { self.parser.parse($0) }

        return parsedFormats.reduce(nil) { bestFormat, nextFormat in
            guard let bestFormat else {
                return nextFormat
            }

            return bestFormat.preferringMoreSpecificFormat(nextFormat)
        }
    }

    private struct TrackSnapshot {
        var playerState: String?
        var persistentID: String?
        var title: String?
        var artist: String?
        var kind: String?
        var bitRate: Int?
        var sampleRate: Double?
        var playerPosition: Double?

        var isStopped: Bool {
            playerState?.lowercased() == "stopped"
        }

        var isPaused: Bool {
            playerState?.lowercased() == "paused"
        }

        var playbackStatus: PlaybackStatus {
            switch playerState?.lowercased() {
            case "playing": .playing
            case "paused": .paused
            case "stopped": .stopped
            default: .unknown
            }
        }

        var startedAt: Date? {
            guard let playerPosition else {
                return nil
            }

            return Date().addingTimeInterval(-playerPosition - 5)
        }

        var identity: String? {
            guard !isStopped else { return nil }
            return [persistentID, title, artist]
                .compactMap { $0 }
                .joined(separator: "\u{1F}")
        }

        var format: AudioFormat? {
            let format = AudioFormat(
                codec: codec,
                bitRate: bitRate,
                sampleRate: sampleRate
            )
            return format.isEmpty ? nil : format
        }

        private var codec: String? {
            guard let kind else { return nil }
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
}

private extension AudioFormat {
    func merging(_ other: AudioFormat) -> AudioFormat {
        let resolvedCodec = codecWithALACPriority(other.codec)

        return AudioFormat(
            codec: resolvedCodec,
            bitDepth: other.bitDepth ?? bitDepth,
            bitRate: resolvedCodec == "ALAC" ? nil : (other.bitRate ?? bitRate),
            sampleRate: other.sampleRate ?? sampleRate
        )
    }

    func preservingBitDepth(from other: AudioFormat?) -> AudioFormat {
        let resolvedCodec = codecWithALACPriority(other?.codec)

        return AudioFormat(
            codec: resolvedCodec,
            bitDepth: bitDepth,
            bitRate: resolvedCodec == "ALAC" ? nil : (other?.bitRate ?? bitRate),
            sampleRate: other?.sampleRate ?? sampleRate
        )
    }

    private func codecWithALACPriority(_ otherCodec: String?) -> String? {
        if codec == "ALAC" || otherCodec == "ALAC" {
            return "ALAC"
        }

        return otherCodec ?? codec
    }

    func preferringMoreSpecificFormat(_ other: AudioFormat) -> AudioFormat {
        let merged = merging(other)

        if other.specificityScore > specificityScore {
            return merged
        }

        return self.merging(other)
    }

    private var specificityScore: Int {
        var score = 0
        if codec != nil { score += 1 }
        if sampleRate != nil { score += 2 }
        if bitDepth != nil { score += 4 }
        return score
    }
}

private extension Array where Element == String {
    func nonEmptyValue(at index: Int) -> String? {
        guard indices.contains(index), !self[index].isEmpty else {
            return nil
        }

        return self[index]
    }
}

struct AudioOutputSnapshot: Sendable {
    let name: String?
    let sampleRate: Double?
}

final class AudioOutputReader {
    func currentOutput() -> AudioOutputSnapshot {
        guard let deviceID = defaultOutputDeviceID() else {
            return AudioOutputSnapshot(name: nil, sampleRate: nil)
        }

        return AudioOutputSnapshot(
            name: deviceName(for: deviceID),
            sampleRate: nominalSampleRate(for: deviceID)
        )
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
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

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)

        return status == noErr ? name as String : nil
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
}

#else
import IsLosslessCore

@main
struct IsLosslessCLI {
    static func main() {
        let formatter = MenuBarTitleFormatter()
        let title = formatter.title(for: AudioFormat(bitDepth: 24, sampleRate: 96_000), status: .detected)
        print("isLossless is a macOS menu bar app. Preview title: \(title)")
    }
}
#endif
