#if os(macOS)
import AppKit
import CoreAudio
import Foundation
import IsLosslessCore
import OSLog

@main
final class IsLosslessApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let formatter = MenuBarTitleFormatter()
    private let monitor = AppleMusicMonitor()
    private var timer: Timer?
    private var state = AppState(status: .detecting)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateMenuBarTitle()
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func startMonitoring() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        state = monitor.snapshot()
        updateMenuBarTitle()
        configureMenu()
    }

    private func updateMenuBarTitle() {
        statusItem.button?.title = formatter.title(for: state.format, status: state.status)
        statusItem.button?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.toolTip = state.accessibilityDescription
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(disabledItem(formatter.title(for: state.format, status: state.status), emphasized: true))
        menu.addItem(.separator())

        if let title = state.trackTitle, !title.isEmpty {
            menu.addItem(disabledItem(title))
        }

        if let artist = state.artistName, !artist.isEmpty {
            menu.addItem(disabledItem(artist, secondary: true))
        }

        if state.trackTitle != nil || state.artistName != nil {
            menu.addItem(.separator())
        }

        menu.addItem(disabledItem("출력"))
        let outputText = [state.outputDeviceName, state.outputSampleRate.map(formatter.formatSampleRate)]
            .compactMap { $0 }
            .joined(separator: " · ")
        menu.addItem(disabledItem(outputText.isEmpty ? "—" : outputText, secondary: true))
        menu.addItem(.separator())
        menu.addItem(disabledItem("상태"))
        menu.addItem(disabledItem(state.statusText, secondary: true))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "새로 고침", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func disabledItem(_ title: String, emphasized: Bool = false, secondary: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if emphasized || secondary {
            let font: NSFont = emphasized ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) : .systemFont(ofSize: NSFont.smallSystemFontSize)
            let color: NSColor = secondary ? .secondaryLabelColor : .labelColor
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        }
        return item
    }
}

struct AppState: Sendable {
    var status: DetectionStatus = .idle
    var format: AudioFormat?
    var trackTitle: String?
    var artistName: String?
    var outputDeviceName: String?
    var outputSampleRate: Double?

    var statusText: String {
        switch status {
        case .idle: "대기 중"
        case .appleMusicNotRunning: "Apple Music이 실행 중이 아닙니다"
        case .notPlaying: "재생 중인 음악이 없습니다"
        case .detecting: "확인 중"
        case .detected: "재생 중"
        case .permissionRequired: "권한이 필요합니다"
        case .failed: "포맷을 확인할 수 없습니다"
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

final class AppleMusicMonitor {
    private let parser = AppleMusicLogParser()
    private let outputReader = AudioOutputReader()

    func snapshot() -> AppState {
        guard isAppleMusicRunning else {
            return AppState(status: .appleMusicNotRunning)
        }

        let track = currentTrack()
        let format = latestFormatFromLogs()
        let output = outputReader.currentOutput()
        var state = AppState(
            status: format == nil ? .detecting : .detected,
            format: format,
            trackTitle: track.title,
            artistName: track.artist,
            outputDeviceName: output.name,
            outputSampleRate: output.sampleRate
        )

        if track.isStopped {
            state.status = .notPlaying
        }

        return state
    }

    private var isAppleMusicRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    private func currentTrack() -> TrackSnapshot {
        let script = """
        tell application "Music"
            if player state is stopped then
                return "stopped||"
            end if
            set trackName to name of current track
            set artistName to artist of current track
            return "playing|" & trackName & "|" & artistName
        end tell
        """

        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let value = descriptor.stringValue else {
            return TrackSnapshot(isStopped: false, title: nil, artist: nil)
        }

        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.first != "stopped" else {
            return TrackSnapshot(isStopped: true, title: nil, artist: nil)
        }

        return TrackSnapshot(
            isStopped: false,
            title: parts.indices.contains(1) ? parts[1] : nil,
            artist: parts.indices.contains(2) ? parts[2] : nil
        )
    }

    private func latestFormatFromLogs() -> AudioFormat? {
        let store: OSLogStore
        do {
            store = try OSLogStore.local()
        } catch {
            return nil
        }

        let position = store.position(date: Date().addingTimeInterval(-12))
        guard let entries = try? store.getEntries(at: position) else {
            return nil
        }

        return entries
            .compactMap { $0 as? OSLogEntryLog }
            .reversed()
            .lazy
            .compactMap { parser.parse($0.composedMessage) }
            .first
    }

    private struct TrackSnapshot {
        let isStopped: Bool
        let title: String?
        let artist: String?
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
