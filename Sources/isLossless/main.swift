#if os(macOS)
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IsLosslessCore
import QuartzCore

let app = NSApplication.shared
let delegate = IsLosslessApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(delegate) {
    app.run()
}

@MainActor
final class IsLosslessApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let formatter = MenuBarTitleFormatter()
    private let iconProvider = MenuBarIconProvider()
    private let monitor = AppleMusicMonitor()
    private var state = AppState(status: .detecting)
    private var menuLabels: [String: NSTextField] = [:]
    private var menuSlidingTextViews: [String: SlidingTextView] = [:]
    private var synchronizedSlidingGroups: [String: SynchronizedSlidingGroup] = [:]
    private var menuImageViews: [String: NSImageView] = [:]
    private var isMenuOpen = false
    private var pendingCacheRefreshWorkItem: DispatchWorkItem?
    private let outputObserver = AudioOutputObserver()

    private enum MenuLayout {
        static let width: CGFloat = 296
        static let horizontalInset: CGFloat = 12
        static let headerTopInset: CGFloat = 8
        static let headerBottomInset: CGFloat = 8
        static let rowVerticalInset: CGFloat = 3
        static let lineSpacing: CGFloat = 2
        static let columnSpacing: CGFloat = 12
        static let analysisIconTextSpacing: CGFloat = 7
        static let analysisDetailRowHeight: CGFloat = 17
        static let headerFontSize: CGFloat = 14
        static let bodyFontSize: CGFloat = 13
        static let analysisIconTextGap: CGFloat = 6
        static let formatOutputArrowWidth: CGFloat = 14
        static let formatOutputArrowInset: CGFloat = 20

        static var contentWidth: CGFloat {
            width - horizontalInset * 2
        }

        static var analysisColumnWidth: CGFloat {
            (contentWidth - columnSpacing) / 2
        }

        static var analysisSingleColumnWidth: CGFloat {
            contentWidth
        }

        static var formatOutputFormatColumnWidth: CGFloat {
            max(0, analysisColumnWidth - formatOutputArrowInset)
        }

        static var slidingDetailTextWidth: CGFloat {
            analysisColumnWidth - 20 - analysisIconTextSpacing
        }

        static var analysisContentHeight: CGFloat {
            analysisDetailRowHeight * 2 + lineSpacing
        }

        static var losslessLabelWidth: CGFloat {
            let font = NSFont.systemFont(ofSize: bodyFontSize, weight: .regular)
            let width = ("고해상도 무손실" as NSString).size(withAttributes: [.font: font]).width
            return ceil(width) + 2
        }

        static var analysisLargeIconWidth: CGFloat {
            max(0, analysisColumnWidth - losslessLabelWidth - analysisIconTextGap)
        }

        static func losslessTextWidth(columnWidth: CGFloat) -> CGFloat {
            max(losslessLabelWidth, columnWidth - analysisLargeIconWidth - analysisIconTextGap)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.preloadCacheDidChange = { [weak self] in
            self?.refresh(forceLogScan: false)
        }
        monitor.startLogStream()
        configureMenu()
        updateMenuBarTitle()
        observeAppleMusicChanges()
        observeAudioOutputChanges()
        refresh()
        print("isLosslessTest is running. Look for the waveform icon in the macOS menu bar.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        pendingCacheRefreshWorkItem?.cancel()
        monitor.stopLogStream()
        outputObserver.stop()
    }

    @objc private func refresh() {
        refresh(forceLogScan: false)
    }

    @objc private func manualRefresh() {
        refresh(forceLogScan: true)
    }

    private func refresh(forceLogScan: Bool) {
        applyState(monitor.snapshot(forceLogScan: forceLogScan))
    }

    private func applyState(_ newState: AppState) {
        let oldLayoutIdentity = state.menuLayoutIdentity
        state = newState
        scheduleCacheRefreshIfNeeded(after: newState.refreshAfter)
        updateMenuBarTitle()
        if isMenuOpen {
            if oldLayoutIdentity == state.menuLayoutIdentity {
                updateMenuLabels()
            } else {
                populateMenu(menu)
            }
        } else {
            populateMenu(menu)
        }
    }

    private func scheduleCacheRefreshIfNeeded(after delay: TimeInterval?) {
        pendingCacheRefreshWorkItem?.cancel()
        pendingCacheRefreshWorkItem = nil

        guard let delay else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refresh(forceLogScan: false)
            }
        }
        pendingCacheRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
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

    private func observeAudioOutputChanges() {
        outputObserver.start { [weak self] in
            DispatchQueue.main.async {
                self?.audioOutputDidChange()
            }
        }
    }

    private func audioOutputDidChange() {
        let output = monitor.currentOutput()
        var newState = state
        newState.outputSampleRate = output.sampleRate
        newState.outputBitDepth = output.bitDepth
        applyState(newState)
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem.button else {
            print("isLossless could not create a menu bar button.")
            return
        }

        if state.status == .unverifiedLossless,
           let icon = iconProvider.inactiveIcon {
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let statusImage: NSImage
            if let sampleRate = state.unverifiedSampleRate {
                let title = iconProvider.titleBeforeIcon(for: formatter.formatSampleRate(sampleRate))
                statusImage = iconProvider.statusImage(for: icon, title: title, font: button.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            } else {
                statusImage = iconProvider.iconOnlyStatusImage(for: icon)
            }
            statusItem.length = iconProvider.itemLength(for: statusImage)
            button.title = ""
            button.image = statusImage
            button.imagePosition = .imageOnly
            button.imageHugsTitle = true
            button.imageScaling = .scaleNone
            button.contentTintColor = nil
        } else if let icon = iconProvider.icon(for: state.format),
           let detail = iconProvider.detailText(for: state.format, formatter: formatter) {
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let title = iconProvider.titleBeforeIcon(for: detail)
            let statusImage = iconProvider.statusImage(for: icon, title: title, font: button.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            statusItem.length = iconProvider.itemLength(for: statusImage)
            button.title = ""
            button.image = statusImage
            button.imagePosition = .imageOnly
            button.imageHugsTitle = true
            button.imageScaling = .scaleNone
            button.contentTintColor = nil
        } else {
            let title = formatter.title(for: state.format, status: state.status)
            if iconProvider.shouldUseInactiveIcon(for: title), let icon = iconProvider.inactiveIcon {
                let statusImage = iconProvider.iconOnlyStatusImage(for: icon)
                statusItem.length = iconProvider.itemLength(for: statusImage)
                button.title = ""
                button.image = statusImage
                button.imagePosition = .imageOnly
                button.imageHugsTitle = true
                button.imageScaling = .scaleNone
                button.contentTintColor = nil
            } else {
                statusItem.length = NSStatusItem.variableLength
                button.image = nil
                button.title = title
                button.imageHugsTitle = true
                button.contentTintColor = nil
            }
        }
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
        applyState(monitor.snapshot(forceLogScan: false))
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
        menuSlidingTextViews.removeAll()
        synchronizedSlidingGroups.removeAll()
        menuImageViews.removeAll()

        menu.addItem(headerItem())
        menu.addItem(analysisItem())
        guard state.playbackStatus != .notRunning else {
            menu.addItem(.separator())
            menu.addItem(quitMenuItem())
            return
        }

        menu.addItem(.separator())
        menu.addItem(formatOutputItem())

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "새로 고침", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        if let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "새로 고침") {
            image.isTemplate = true
            refreshItem.image = image
        }
        menu.addItem(refreshItem)

        menu.addItem(quitMenuItem())
    }

    private func updateMenuLabels() {
        menuLabels["analysis-line-1"]?.stringValue = analysisStatusText
        menuSlidingTextViews["analysis-detail"]?.stringValue = analysisDetailText
        menuSlidingTextViews["track-title"]?.stringValue = trackTitleText
        menuSlidingTextViews["track-artist"]?.stringValue = artistText
        synchronizedSlidingGroups["track-metadata"]?.restart()
        menuImageViews["analysis-detail-icon"]?.image = analysisDetailIcon
        menuLabels["format-detail"]?.stringValue = formatText
        menuLabels["output-detail"]?.stringValue = outputText
    }

    private func quitMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.target = NSApp
        return item
    }

    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem()
        let title = NSTextField(labelWithString: "isLossless")
        title.font = .systemFont(ofSize: MenuLayout.headerFontSize, weight: .semibold)
        title.textColor = .labelColor
        item.view = menuItemView(
            arrangedSubviews: [title],
            topInset: MenuLayout.headerTopInset,
            bottomInset: MenuLayout.headerBottomInset
        )
        return item
    }

    private func analysisItem() -> NSMenuItem {
        let item = NSMenuItem()
        let usesTwoColumns = hasCurrentTrack
        let leftColumnWidth = usesTwoColumns ? MenuLayout.analysisColumnWidth : MenuLayout.analysisSingleColumnWidth
        let textColumnWidth = MenuLayout.losslessTextWidth(columnWidth: leftColumnWidth)

        let statusLabel = NSTextField(labelWithString: analysisStatusText)
        statusLabel.font = .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .regular)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        menuLabels["analysis-line-1"] = statusLabel
        let statusRow = fixedHeightRow(containing: statusLabel, width: textColumnWidth)

        let detailIconView = NSImageView(image: analysisDetailIcon)
        detailIconView.imageScaling = .scaleProportionallyUpOrDown
        detailIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailIconView.widthAnchor.constraint(equalToConstant: MenuLayout.analysisLargeIconWidth),
            detailIconView.heightAnchor.constraint(equalToConstant: MenuLayout.analysisContentHeight)
        ])
        menuImageViews["analysis-detail-icon"] = detailIconView

        let detailText = SlidingTextView(
            width: textColumnWidth,
            height: MenuLayout.analysisDetailRowHeight,
            font: .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .regular),
            textColor: .labelColor
        )
        detailText.stringValue = analysisDetailText
        menuSlidingTextViews["analysis-detail"] = detailText

        let textColumn = NSStackView(views: [statusRow, detailText])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = MenuLayout.lineSpacing
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.widthAnchor.constraint(equalToConstant: textColumnWidth).isActive = true

        let leftColumn = NSStackView(views: [detailIconView, textColumn])
        leftColumn.orientation = .horizontal
        leftColumn.alignment = .centerY
        leftColumn.spacing = MenuLayout.analysisIconTextGap
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.widthAnchor.constraint(equalToConstant: leftColumnWidth).isActive = true

        var columnViews: [NSView] = [leftColumn]

        if usesTwoColumns {
            let trackTitleTextView = SlidingTextView(
                width: MenuLayout.analysisColumnWidth,
                height: MenuLayout.analysisDetailRowHeight,
                font: .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .semibold),
                textColor: .labelColor,
                startsAutomatically: false
            )
            trackTitleTextView.stringValue = trackTitleText
            menuSlidingTextViews["track-title"] = trackTitleTextView

            let artistTextView = SlidingTextView(
                width: MenuLayout.analysisColumnWidth,
                height: MenuLayout.analysisDetailRowHeight,
                font: .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .regular),
                textColor: .labelColor,
                startsAutomatically: false
            )
            artistTextView.stringValue = artistText
            menuSlidingTextViews["track-artist"] = artistTextView
            synchronizedSlidingGroups["track-metadata"] = SynchronizedSlidingGroup(views: [trackTitleTextView, artistTextView])

            let rightColumn = NSStackView(views: [trackTitleTextView, artistTextView])
            rightColumn.orientation = .vertical
            rightColumn.alignment = .leading
            rightColumn.spacing = MenuLayout.lineSpacing
            rightColumn.translatesAutoresizingMaskIntoConstraints = false
            rightColumn.widthAnchor.constraint(equalToConstant: MenuLayout.analysisColumnWidth).isActive = true
            columnViews.append(rightColumn)
        }

        let columns = NSStackView(views: columnViews)
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = MenuLayout.columnSpacing

        item.view = menuItemView(arrangedSubviews: [columns], fixedContentHeight: MenuLayout.analysisContentHeight)
        return item
    }

    private func formatOutputItem() -> NSMenuItem {
        let item = NSMenuItem()

        let formatColumn = twoLineInfoColumn(
            title: "포맷",
            detail: formatText,
            titleKey: "format-title",
            detailKey: "format-detail",
            width: MenuLayout.formatOutputFormatColumnWidth
        )
        let outputColumn = twoLineInfoColumn(
            title: "출력",
            detail: outputText,
            titleKey: "output-title",
            detailKey: "output-detail",
            width: MenuLayout.analysisColumnWidth
        )
        let arrowView = formatOutputArrowView()

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(formatColumn)
        contentView.addSubview(outputColumn)
        contentView.addSubview(arrowView)
        formatColumn.translatesAutoresizingMaskIntoConstraints = false
        outputColumn.translatesAutoresizingMaskIntoConstraints = false
        arrowView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: MenuLayout.contentWidth),
            contentView.heightAnchor.constraint(equalToConstant: MenuLayout.analysisContentHeight),
            formatColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            formatColumn.topAnchor.constraint(equalTo: contentView.topAnchor),
            outputColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MenuLayout.analysisColumnWidth + MenuLayout.columnSpacing),
            outputColumn.topAnchor.constraint(equalTo: contentView.topAnchor),
            arrowView.leadingAnchor.constraint(equalTo: formatColumn.trailingAnchor, constant: 8),
            arrowView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        item.view = menuItemView(arrangedSubviews: [contentView], fixedContentHeight: MenuLayout.analysisContentHeight)
        return item
    }

    private func twoLineInfoColumn(title: String, detail: String, titleKey: String, detailKey: String, width: CGFloat) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        menuLabels[titleKey] = titleLabel

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .regular)
        detailLabel.textColor = .labelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        menuLabels[detailKey] = detailLabel

        let column = NSStackView(views: [
            fixedHeightRow(containing: titleLabel, width: width),
            fixedHeightRow(containing: detailLabel, width: width)
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MenuLayout.lineSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        return column
    }

    private func formatOutputArrowView() -> NSView {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "포맷에서 출력")
        imageView.image?.isTemplate = true
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: MenuLayout.formatOutputArrowWidth),
            imageView.heightAnchor.constraint(equalToConstant: MenuLayout.analysisDetailRowHeight)
        ])
        return imageView
    }

    private func fixedHeightRow(containing view: NSView, width: CGFloat) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: width),
            row.heightAnchor.constraint(equalToConstant: MenuLayout.analysisDetailRowHeight),
            view.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func informationalItem(_ title: String, key: String? = nil, emphasized: Bool = false, secondary: Bool = false, compact: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        let label = NSTextField(labelWithString: title)
        let fontSize: CGFloat = compact ? MenuLayout.bodyFontSize : MenuLayout.headerFontSize
        label.font = .systemFont(ofSize: fontSize, weight: emphasized ? .semibold : .regular)
        label.textColor = key == "output-title" ? .labelColor : (secondary ? .secondaryLabelColor : .labelColor)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        item.view = menuItemView(
            arrangedSubviews: [label],
            topInset: compact ? 2 : MenuLayout.rowVerticalInset,
            bottomInset: compact ? 2 : MenuLayout.rowVerticalInset
        )
        if let key {
            menuLabels[key] = label
        }
        return item
    }

    private func spacerItem(height: CGFloat) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: MenuLayout.width, height: height))
        return item
    }

    private func menuItemView(
        arrangedSubviews: [NSView],
        topInset: CGFloat = MenuLayout.rowVerticalInset,
        bottomInset: CGFloat = MenuLayout.rowVerticalInset,
        fixedContentHeight: CGFloat? = nil
    ) -> NSView {
        let stack = NSStackView(views: arrangedSubviews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MenuLayout.lineSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for view in arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(lessThanOrEqualToConstant: MenuLayout.contentWidth).isActive = true
        }

        let contentHeight = fixedContentHeight ?? stack.fittingSize.height
        let height = contentHeight + topInset + bottomInset
        let container = NSView(frame: NSRect(x: 0, y: 0, width: MenuLayout.width, height: height))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: MenuLayout.horizontalInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -MenuLayout.horizontalInset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottomInset)
        ])
        if let fixedContentHeight {
            stack.heightAnchor.constraint(equalToConstant: fixedContentHeight).isActive = true
        }
        return container
    }

    private var analysisStatusText: String {
        state.statusText
    }

    private var formatText: String {
        guard hasCurrentTrack,
              state.status == .detected,
              let format = state.format else {
            return "—"
        }

        if format.codec == "ALAC" {
            let bitDepthText = format.bitDepth.map { "\($0)비트" }
            let sampleRateText = format.sampleRate.map(formatter.formatSampleRate)
            let text = [bitDepthText, sampleRateText]
                .compactMap { $0 }
                .joined(separator: " ")
            return text.isEmpty ? "—" : text
        }

        return format.bitRate.map { "\($0)kbps" } ?? "—"
    }

    private var outputText: String {
        let bitDepthText = state.outputBitDepth.map { "\($0)비트" }
        let sampleRateText = state.outputSampleRate.map(formatter.formatSampleRate)
        let text = [bitDepthText, sampleRateText]
            .compactMap { $0 }
            .joined(separator: " ")
        return text.isEmpty ? "—" : text
    }

    private var analysisDetailText: String {
        guard hasCurrentTrack else {
            return "—"
        }

        if state.status == .unverifiedLossless {
            return "확인되지 않은 무손실"
        }

        if state.status == .failed {
            return "확인 실패"
        }

        guard state.status != .detecting else {
            return "확인 중"
        }

        guard state.format?.codec == "ALAC",
              let sampleRate = state.format?.sampleRate else {
            return "무손실 아님"
        }

        let losslessLabel = sampleRate > 48_000 ? "고해상도 무손실" : "무손실"
        return losslessLabel
    }

    private var analysisDetailIcon: NSImage {
        guard hasCurrentTrack else {
            return iconProvider.inactiveMenuIcon ?? NSImage(size: NSSize(width: 20, height: 11))
        }

        if state.format?.codec == "ALAC",
           let icon = iconProvider.menuIcon(for: state.format) {
            return icon
        }

        if state.status != .detecting && state.status != .failed && state.status != .unverifiedLossless {
            return iconProvider.inactiveOtherMenuIcon ?? NSImage(size: NSSize(width: 20, height: 11))
        }

        return iconProvider.inactiveMenuIcon ?? NSImage(size: NSSize(width: 20, height: 11))
    }

    private var trackTitleText: String {
        state.trackTitle ?? "—"
    }

    private var artistText: String {
        let text = [state.artistName, state.albumName]
            .compactMap { $0 }
            .joined(separator: " — ")
        return text.isEmpty ? "—" : text
    }

    private var hasCurrentTrack: Bool {
        state.trackTitle != nil || state.artistName != nil || state.albumName != nil
    }

}

private struct MenuBarIconProvider {
    private static let leadingPadding: CGFloat = 0
    private static let trailingPadding: CGFloat = 1
    private static let statusImageHeight: CGFloat = 18
    private static let iconVerticalOffset: CGFloat = -1
    private let losslessIcon = Self.loadIcon(named: "isLossless_logo_black", targetHeight: 14)
    private let otherIcon = Self.loadIcon(named: "isLossless_logo_crossed_black", targetHeight: 14)
    private let menuLosslessIcon = Self.loadIcon(named: "isLossless_logo_black", targetHeight: 36)
    private let menuOtherIcon = Self.loadIcon(named: "isLossless_logo_crossed_black", targetHeight: 36)
    let inactiveIcon = Self.loadIcon(named: "isLossless_logo_black", targetHeight: 14)?.inactive(alpha: 0.6)
    let inactiveMenuIcon = Self.loadIcon(named: "isLossless_logo_black", targetHeight: 36)?.inactive(alpha: 0.35)
    let inactiveOtherMenuIcon = Self.loadIcon(named: "isLossless_logo_crossed_black", targetHeight: 36)?.inactive(alpha: 0.35)

    func icon(for format: AudioFormat?) -> NSImage? {
        switch format?.codec {
        case "ALAC":
            return losslessIcon
        case "AAC":
            return otherIcon
        default:
            return nil
        }
    }

    func menuIcon(for format: AudioFormat?) -> NSImage? {
        switch format?.codec {
        case "ALAC":
            return menuLosslessIcon?.copy() as? NSImage
        case "AAC":
            return menuOtherIcon?.copy() as? NSImage
        default:
            return nil
        }
    }

    func detailText(for format: AudioFormat?, formatter: MenuBarTitleFormatter) -> String? {
        switch format?.codec {
        case "ALAC":
            return format?.sampleRate.map(formatter.formatSampleRate)
        case "AAC":
            if let bitRate = format?.bitRate {
                return "\(bitRate)kbps"
            }

            if let sampleRate = format?.sampleRate {
                return formatter.formatSampleRate(sampleRate)
            }

            return "AAC"
        default:
            return nil
        }
    }

    func titleBeforeIcon(for detail: String) -> String {
        "\(detail)  "
    }

    func statusImage(for icon: NSImage, title: String, font: NSFont) -> NSImage {
        statusImage(for: icon, title: title, font: font, minimumWidth: 0)
    }

    func iconOnlyStatusImage(for icon: NSImage) -> NSImage {
        statusImage(
            for: icon,
            title: "",
            font: .systemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            minimumWidth: max(18, icon.size.width + Self.leadingPadding + Self.trailingPadding)
        )
    }

    private func statusImage(for icon: NSImage, title: String, font: NSFont, minimumWidth: CGFloat) -> NSImage {
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let textSize = text.size(withAttributes: attributes)
        let textWidth = ceil(textSize.width)
        let contentWidth = ceil(Self.leadingPadding + textWidth + icon.size.width + Self.trailingPadding)
        let imageWidth = max(contentWidth, ceil(minimumWidth))
        let imageSize = NSSize(width: imageWidth, height: Self.statusImageHeight)
        let image = NSImage(size: imageSize)

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: imageSize).fill()

        let textY = ((Self.statusImageHeight - textSize.height) / 2).rounded(.down)
        if textWidth > 0 {
            text.draw(at: NSPoint(x: Self.leadingPadding, y: textY), withAttributes: attributes)
        }

        let iconY = ((Self.statusImageHeight - icon.size.height) / 2).rounded(.down) + Self.iconVerticalOffset
        let iconX = imageWidth - Self.trailingPadding - icon.size.width
        icon.draw(
            in: NSRect(x: iconX, y: iconY, width: icon.size.width, height: icon.size.height),
            from: NSRect(origin: .zero, size: icon.size),
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func itemLength(for image: NSImage) -> CGFloat {
        image.size.width
    }

    func shouldUseInactiveIcon(for title: String) -> Bool {
        title == "—" || title == "isLossless"
    }

    private static func loadIcon(named name: String, targetHeight: CGFloat) -> NSImage? {
        guard let url = resourceURL(named: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        let aspectRatio = image.size.width / image.size.height
        image.size = NSSize(width: (targetHeight * aspectRatio).rounded(), height: targetHeight)
        image.isTemplate = true
        return image
    }

    private static func resourceURL(named name: String, withExtension fileExtension: String) -> URL? {
        let resourceBundleName = "isLossless_isLossless.bundle"
        let fileName = "\(name).\(fileExtension)"
        var candidates: [URL] = []

        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            candidates.append(url)
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundleURL = resourceURL.appendingPathComponent(resourceBundleName)
            if let url = Bundle(url: bundleURL)?.url(forResource: name, withExtension: fileExtension) {
                candidates.append(url)
            }
            candidates.append(bundleURL.appendingPathComponent(fileName))
        }

        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(resourceBundleName)
                    .appendingPathComponent(fileName)
            )
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private extension NSImage {
    func inactive(alpha: CGFloat) -> NSImage {
        isTemplate = false
        let inactiveImage = NSImage(size: size)
        inactiveImage.lockFocus()
        draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: size),
            operation: .sourceOver,
            fraction: alpha
        )
        inactiveImage.unlockFocus()
        inactiveImage.isTemplate = false
        return inactiveImage
    }
}

private extension NSAttributedString {
    static func menuIcon(_ image: NSImage) -> NSAttributedString {
        image.size = NSSize(width: 20, height: 11)
        image.isTemplate = true

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}

final class SlidingTextView: NSView {
    private let textLayers = [CATextLayer(), CATextLayer()]
    private var displayText = ""
    private let fixedSize: NSSize
    private let font: NSFont
    private let textColor: NSColor
    private let startsAutomatically: Bool
    private let interItemGap: CGFloat = 36
    private var layoutKey = ""
    private var cycleDistance: CGFloat = 0
    private var leadingLayerIndex = 0
    private var animationGeneration = 0
    private var hasOverflow = false

    var stringValue: String {
        get { displayText }
        set {
            guard displayText != newValue else {
                return
            }

            displayText = newValue
            layoutKey = ""
            needsLayout = true
        }
    }

    init(width: CGFloat, height: CGFloat, font: NSFont, textColor: NSColor, startsAutomatically: Bool = true) {
        self.fixedSize = NSSize(width: width, height: height)
        self.font = font
        self.textColor = textColor
        self.startsAutomatically = startsAutomatically
        super.init(frame: NSRect(origin: .zero, size: fixedSize))

        wantsLayer = true
        layer?.masksToBounds = true

        textLayers.forEach {
            configure($0)
            layer?.addSublayer($0)
        }

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: fixedSize.width),
            heightAnchor.constraint(equalToConstant: fixedSize.height)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        fixedSize
    }

    override func layout() {
        super.layout()
        updateTextLayout()
    }

    private func updateTextLayout() {
        let textWidth = ceil((displayText as NSString).size(withAttributes: [.font: font]).width)
        let shouldSlide = textWidth > bounds.width
        let nextLayoutKey = "\(displayText)|\(bounds.width)|\(bounds.height)|\(shouldSlide)"
        guard nextLayoutKey != layoutKey else {
            return
        }

        layoutKey = nextLayoutKey
        animationGeneration += 1
        cycleDistance = textWidth + interItemGap
        hasOverflow = shouldSlide
        let attributedText = NSAttributedString(
            string: displayText,
            attributes: [.font: font, .foregroundColor: textColor]
        )

        for (index, textLayer) in textLayers.enumerated() {
            textLayer.string = attributedText
            textLayer.frame = textFrame(x: CGFloat(index) * cycleDistance, width: textWidth)
            textLayer.removeAnimation(forKey: "slide")
            textLayer.transform = CATransform3DIdentity
            textLayer.isHidden = index > 0
        }
        leadingLayerIndex = 0

        guard shouldSlide else {
            return
        }

        textLayers.forEach { $0.isHidden = false }
        if startsAutomatically {
            let generation = animationGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.runMarqueeStep(generation: generation)
            }
        }
    }

    var requiresSliding: Bool {
        layoutSubtreeIfNeeded()
        return hasOverflow
    }

    var preferredSlideDuration: Double {
        max(2.0, Double(cycleDistance / 32))
    }

    func performSynchronizedStep(duration: Double) {
        layoutSubtreeIfNeeded()
        guard requiresSliding else {
            return
        }

        let generation = animationGeneration
        runMarqueeStep(generation: generation, slideDuration: duration, schedulesNextStep: false)
    }

    private func configure(_ textLayer: CATextLayer) {
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.isWrapped = false
    }

    private func textFrame(x: CGFloat, width: CGFloat) -> CGRect {
        let textHeight = ceil(font.ascender - font.descender)
        let y = ((bounds.height - textHeight) / 2).rounded(.down)
        return CGRect(x: x, y: y, width: width, height: textHeight)
    }

    private func runMarqueeStep(generation: Int) {
        runMarqueeStep(generation: generation, slideDuration: max(2.0, Double(cycleDistance / 32)), schedulesNextStep: true)
    }

    private func runMarqueeStep(generation: Int, slideDuration: Double, schedulesNextStep: Bool) {
        guard generation == animationGeneration, cycleDistance > 0 else {
            return
        }

        let outgoingLayer = textLayers[leadingLayerIndex]
        let incomingLayer = textLayers[1 - leadingLayerIndex]
        setFrameX(0, for: outgoingLayer)
        setFrameX(cycleDistance, for: incomingLayer)

        let holdDuration = 3.0
        animate(outgoingLayer, fromX: 0, toX: -cycleDistance, duration: slideDuration)
        animate(incomingLayer, fromX: cycleDistance, toX: 0, duration: slideDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + slideDuration) { [weak self] in
            guard let self, generation == self.animationGeneration else {
                return
            }

            self.setFrameX(self.cycleDistance, for: outgoingLayer)
            self.setFrameX(0, for: incomingLayer)
            self.leadingLayerIndex = 1 - self.leadingLayerIndex

            if schedulesNextStep {
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
                    self?.runMarqueeStep(generation: generation)
                }
            }
        }
    }

    private func setFrameX(_ x: CGFloat, for textLayer: CATextLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame.origin.x = x
        CATransaction.commit()
    }

    private func animate(_ textLayer: CATextLayer, fromX: CGFloat, toX: CGFloat, duration: Double) {
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = fromX + textLayer.bounds.width / 2
        animation.toValue = toX + textLayer.bounds.width / 2
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        setFrameX(toX, for: textLayer)
        textLayer.add(animation, forKey: "slide")
    }
}

@MainActor
final class SynchronizedSlidingGroup {
    private let views: [SlidingTextView]
    private let initialDelay = 1.0
    private let holdDuration = 3.0
    private var generation = 0
    private var contentKey = ""

    init(views: [SlidingTextView]) {
        self.views = views
        restart(force: true)
    }

    func restart(force: Bool = false) {
        let nextContentKey = views.map { $0.stringValue }.joined(separator: "\u{1F}")
        guard force || nextContentKey != contentKey else {
            return
        }

        contentKey = nextContentKey
        generation += 1
        views.forEach { $0.layoutSubtreeIfNeeded() }
        let currentGeneration = generation

        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.runStep(generation: currentGeneration)
        }
    }

    private func runStep(generation: Int) {
        guard generation == self.generation else {
            return
        }

        let slidingViews = views.filter { $0.requiresSliding }
        guard !slidingViews.isEmpty else {
            return
        }

        let slideDuration = slidingViews
            .map { $0.preferredSlideDuration }
            .max() ?? 0
        slidingViews.forEach { $0.performSynchronizedStep(duration: $0.preferredSlideDuration) }

        DispatchQueue.main.asyncAfter(deadline: .now() + slideDuration + holdDuration) { [weak self] in
            self?.runStep(generation: generation)
        }
    }
}

struct AppState: Sendable {
    var status: DetectionStatus = .idle
    var playbackStatus: PlaybackStatus = .unknown
    var format: AudioFormat?
    var trackIdentity: String?
    var trackTitle: String?
    var artistName: String?
    var albumName: String?
    var outputSampleRate: Double?
    var outputBitDepth: Int?
    var refreshAfter: TimeInterval?
    var unverifiedSampleRate: Double?

    var menuLayoutIdentity: String {
        trackTitle != nil || artistName != nil || albumName != nil ? "analysis-two-column" : "analysis-single-column"
    }

    var statusText: String {
        return switch playbackStatus {
        case .playing: "재생 중"
        case .paused: "일시 정지"
        case .stopped: "재생 중이 아님"
        case .notRunning: "Apple Music 재생 중이 아님"
        case .unknown: "확인 중"
        }
    }

    var accessibilityDescription: String {
        switch status {
        case .detected:
            let title = MenuBarTitleFormatter().title(for: format, status: status)
            return "현재 Apple Music 포맷: \(title)"
        case .unverifiedLossless:
            return "현재 Apple Music 포맷: 확인되지 않은 무손실"
        case .failed:
            return "현재 Apple Music 포맷 확인 실패"
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

@MainActor
final class AppleMusicMonitor {
    private let parser = AppleMusicLogParser()
    private let outputReader = AudioOutputReader()
    private let localAudioFormatReader = LocalAudioFormatReader()
    private lazy var logStream = AppleMusicLogStream { [weak self] entries in
        Task { @MainActor in
            self?.rememberPreloadLogEntries(entries)
        }
    }
    private var preloadAssembler = AppleMusicPreloadAssembler()
    private var preloadCache = AppleMusicPreloadCache()
    private var preloadCacheRevision = 0
    private var lastResolvedPreloadCacheRevision = -1
    private var cachedFormat: AudioFormat?
    private var currentTrackIdentity: String?
    private var currentTrackDetectionStartedAt: Date?
    private var currentTrackAppleScriptSampleRate: Double?
    private var cachedStatus: DetectionStatus?
    private var cachedFormatSource: FormatSource?
    private var cachedUnverifiedSampleRate: Double?
    private let initialCacheLookupDelay: TimeInterval = 0.5
    private let cacheLookupWaitLimit: TimeInterval = 3
    private let playbackLosslessPromotionWindow: TimeInterval = 1
    private let playbackLosslessPromotionDeliveryTolerance: TimeInterval = 0.25
    private let emptyCacheRetryInterval: TimeInterval = 0.5
    private var firstCacheLookupAt: Date?
    private var cacheLookupDeadline: Date?
    private var nextCacheRefreshAt: Date?
    var preloadCacheDidChange: (() -> Void)?

    private enum FormatSource {
        case localFile
        case preloadCache
        case playbackLog
        case fallback
    }

    func startLogStream() {
        logStream.start()
    }

    func stopLogStream() {
        logStream.stop()
    }

    func currentOutput() -> AudioOutputSnapshot {
        outputReader.currentOutput()
    }

    func snapshot(forceLogScan: Bool = false) -> AppState {
        let now = Date()
        guard isAppleMusicRunning else {
            resetPlaybackTracking()
            return AppState(status: .appleMusicNotRunning, playbackStatus: .notRunning)
        }

        let track = currentTrack()
        if !track.isStopped,
           track.identity == currentTrackIdentity {
            currentTrackAppleScriptSampleRate = track.sampleRate ?? currentTrackAppleScriptSampleRate
        }

        if track.isStopped {
            resetPlaybackTracking()
        } else if track.identity != currentTrackIdentity {
            beginDetection(for: track, now: now)
        } else if forceLogScan, !track.isStopped {
            debugLog("manual refresh requested: target title=\(Self.debugQuote(track.title)) durationInt=\(Self.debugDurationInt(track.duration))")
            beginDetection(for: track, now: now)
        } else if cachedStatus == .detecting {
            advanceCacheLookupIfNeeded(for: track, now: now)
        } else if cachedStatus == .unverifiedLossless {
            rememberUnverifiedSampleRate(from: track)
        } else if cachedFormatSource == .playbackLog,
                  preloadCacheRevision != lastResolvedPreloadCacheRevision {
            refinePlaybackLogFormatFromPreloadCache(for: track)
        } else if cachedFormat != nil {
            cachedFormat = cachedFormat?.preservingBitDepth(from: track.format) ?? track.format
        }

        return makeState(for: track, format: cachedFormat, status: cachedStatus, now: now)
    }

    private func resetPlaybackTracking() {
        cachedFormat = nil
        cachedStatus = nil
        cachedFormatSource = nil
        cachedUnverifiedSampleRate = nil
        currentTrackIdentity = nil
        currentTrackDetectionStartedAt = nil
        currentTrackAppleScriptSampleRate = nil
        clearCacheLookupSchedule()
    }

    private func fallbackAACFormat(from track: TrackSnapshot) -> AudioFormat? {
        guard let bitRate = track.bitRate,
              bitRate > 0 else {
            return nil
        }

        return AudioFormat(codec: "AAC", bitRate: bitRate, sampleRate: track.sampleRate)
    }

    private func makeState(for track: TrackSnapshot, format: AudioFormat?, status: DetectionStatus? = nil, now: Date = Date()) -> AppState {
        let output = outputReader.currentOutput()
        let resolvedStatus = status ?? (format == nil ? .detecting : .detected)
        let resolvedUnverifiedSampleRate = resolvedStatus == .unverifiedLossless
            ? cachedUnverifiedSampleRate ?? track.sampleRate
            : nil

        var state = AppState(
            status: resolvedStatus,
            playbackStatus: track.playbackStatus,
            format: format,
            trackIdentity: track.identity,
            trackTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            outputSampleRate: output.sampleRate,
            outputBitDepth: output.bitDepth,
            refreshAfter: cacheRefreshDelay(now: now),
            unverifiedSampleRate: resolvedUnverifiedSampleRate
        )

        if track.isStopped {
            state.status = .notPlaying
            state.format = nil
        }

        return state
    }

    private var isAppleMusicRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
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
            set albumName to ""
            set trackKind to ""
            set trackBitRate to ""
            set trackSampleRate to ""
            set trackDuration to ""
            set trackPosition to ""
            set trackLocation to ""
            set trackDatabaseID to ""
            try
                set trackID to persistent ID of currentTrack as text
            end try
            try
                set trackDatabaseID to database ID of currentTrack as text
            end try
            try
                set trackName to name of currentTrack as text
            end try
            try
                set artistName to artist of currentTrack as text
            end try
            try
                set albumName to album of currentTrack as text
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
                set trackDuration to duration of currentTrack as text
            end try
            try
                set trackPosition to player position as text
            end try
            try
                set currentLocation to location of currentTrack
                if currentLocation is not missing value then
                    set trackLocation to POSIX path of (currentLocation as alias)
                end if
            end try
            if trackLocation is "" then
                try
                    set libraryTrack to first file track of library playlist 1 whose persistent ID is trackID
                    set libraryLocation to location of libraryTrack
                    if libraryLocation is not missing value then
                        set trackLocation to POSIX path of (libraryLocation as alias)
                    end if
                end try
            end if
            if trackLocation is "" then
                try
                    set libraryTrack to first file track of library playlist 1 whose database ID is (trackDatabaseID as integer)
                    set libraryLocation to location of libraryTrack
                    if libraryLocation is not missing value then
                        set trackLocation to POSIX path of (libraryLocation as alias)
                    end if
                end try
            end if
            return playerState & fieldDelimiter & trackID & fieldDelimiter & trackName & fieldDelimiter & artistName & fieldDelimiter & albumName & fieldDelimiter & trackKind & fieldDelimiter & trackBitRate & fieldDelimiter & trackSampleRate & fieldDelimiter & trackDuration & fieldDelimiter & trackPosition & fieldDelimiter & trackLocation
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
            album: parts.nonEmptyValue(at: 4),
            kind: parts.nonEmptyValue(at: 5),
            bitRate: parts.nonEmptyValue(at: 6).flatMap(Int.init),
            sampleRate: Self.parseAppleScriptSampleRate(parts.nonEmptyValue(at: 7)),
            duration: parts.nonEmptyValue(at: 8).flatMap(Double.init),
            playerPosition: parts.nonEmptyValue(at: 9).flatMap(Double.init),
            localFilePath: parts.nonEmptyValue(at: 10)
        )
    }

    private static func parseAppleScriptSampleRate(_ value: String?) -> Double? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let direct = Double(trimmed) {
            return normalizeSampleRate(direct)
        }

        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        let commaGroups = compact.split(separator: ",", omittingEmptySubsequences: false)
        if commaGroups.count > 1,
           commaGroups.dropFirst().allSatisfy({ $0.count == 3 }),
           let grouped = Double(commaGroups.joined()) {
            return normalizeSampleRate(grouped)
        }

        if let decimalComma = Double(compact.replacingOccurrences(of: ",", with: ".")) {
            return normalizeSampleRate(decimalComma)
        }

        return nil
    }

    private static func normalizeSampleRate(_ sampleRate: Double) -> Double {
        sampleRate > 0 && sampleRate < 1_000 ? sampleRate * 1_000 : sampleRate
    }

    private func beginDetection(for track: TrackSnapshot, now: Date) {
        currentTrackIdentity = track.identity
        currentTrackDetectionStartedAt = now
        currentTrackAppleScriptSampleRate = track.sampleRate
        cachedUnverifiedSampleRate = nil
        cachedFormatSource = nil

        if let localFileURL = track.localFileURL {
            switch localAudioFormatReader.format(for: localFileURL) {
            case .success(let localFormat):
                let resolvedFormat = localFormat.fillingMissingFields(from: track.format)
                cachedFormat = resolvedFormat
                cachedStatus = .detected
                cachedFormatSource = .localFile
                clearCacheLookupSchedule()
                debugLog("format: local file detected path=\(Self.debugQuote(localFileURL.path)) \(debugFormat(resolvedFormat))")
                return

            case .failure(let error):
                debugLog("format: local file probe failed path=\(Self.debugQuote(localFileURL.path)) error=\(error.localizedDescription); falling back to preload cache")
            }
        } else if track.kindSuggestsDownloadedAppleMusicFile {
            debugLog("format: local file location unavailable kind=\(Self.debugQuote(track.kind)) title=\(Self.debugQuote(track.title)); falling back to preload cache")
        }

        beginCacheLookup(for: track, now: now)
    }

    private func beginCacheLookup(for track: TrackSnapshot, now: Date) {
        cachedFormat = nil
        cachedStatus = .detecting
        cachedFormatSource = nil
        cachedUnverifiedSampleRate = nil
        currentTrackIdentity = track.identity
        currentTrackAppleScriptSampleRate = track.sampleRate ?? currentTrackAppleScriptSampleRate
        firstCacheLookupAt = now.addingTimeInterval(initialCacheLookupDelay)
        cacheLookupDeadline = now.addingTimeInterval(cacheLookupWaitLimit)
        nextCacheRefreshAt = firstCacheLookupAt
        debugLog("cache lookup scheduled: initialDelay=\(initialCacheLookupDelay)s deadline=\(debugTime(cacheLookupDeadline)) target title=\(Self.debugQuote(track.title)) durationInt=\(Self.debugDurationInt(track.duration))")
    }

    private func advanceCacheLookupIfNeeded(for track: TrackSnapshot, now: Date) {
        if let firstCacheLookupAt, now < firstCacheLookupAt {
            nextCacheRefreshAt = firstCacheLookupAt
            return
        }

        if let nextCacheRefreshAt,
           now < nextCacheRefreshAt,
           preloadCacheRevision == lastResolvedPreloadCacheRevision {
            return
        }

        resolveFormatFromPreloadCache(for: track, now: now)
    }

    private func resolveFormatFromPreloadCache(for track: TrackSnapshot, now: Date) {
        lastResolvedPreloadCacheRevision = preloadCacheRevision
        debugLog("cache lookup: target title=\(Self.debugQuote(track.title)) durationInt=\(Self.debugDurationInt(track.duration)) kind=\(Self.debugQuote(track.kind)) cached=\(preloadCache.count)")

        switch preloadCache.lookup(title: track.title, duration: track.duration) {
        case .found(let record):
            let resolvedFormat = track.format?.merging(record.format) ?? record.format
            if resolvedFormat.isReadyForDisplay {
                cachedFormat = resolvedFormat
                cachedStatus = .detected
                cachedFormatSource = .preloadCache
                cachedUnverifiedSampleRate = nil
                clearCacheLookupSchedule()
                debugLog("format: found queueItemID=\(record.queueItemID) group=\(record.groupID) \(debugFormat(resolvedFormat))")
            } else {
                resolveNonAlacFallback(from: track)
                clearCacheLookupSchedule()
                debugLog("format: completed preload format not display-ready queueItemID=\(record.queueItemID) group=\(record.groupID); fallback \(debugFormat(cachedFormat)) status=\(cachedStatusDescription)")
            }

        case .fallbackAAC:
            handlePreloadCacheMiss(for: track, now: now, reason: "no-exact-match")

        case .failed:
            handlePreloadCacheMiss(for: track, now: now, reason: "cache-empty")
        }
    }

    private func resolveNonAlacFallback(from track: TrackSnapshot) {
        if let aacFormat = fallbackAACFormat(from: track) {
            cachedFormat = aacFormat
            cachedStatus = .detected
            cachedFormatSource = .fallback
            cachedUnverifiedSampleRate = nil
        } else {
            cachedFormat = nil
            cachedStatus = .unverifiedLossless
            cachedFormatSource = .fallback
            rememberUnverifiedSampleRate(from: track)
        }
    }

    private func rememberUnverifiedSampleRate(from track: TrackSnapshot) {
        cachedUnverifiedSampleRate = track.sampleRate ?? cachedUnverifiedSampleRate
    }

    private func handlePreloadCacheMiss(for track: TrackSnapshot, now: Date, reason: String) {
        guard let cacheLookupDeadline, now < cacheLookupDeadline else {
            if reason == "cache-empty" {
                cachedFormat = nil
                cachedStatus = .failed
                cachedFormatSource = nil
                cachedUnverifiedSampleRate = nil
                clearCacheLookupSchedule()
                debugLog("format: preload cache empty after wait; failed without AAC fallback")
                return
            }

            if reason == "no-exact-match" {
                debugPreloadCacheLookupFailure(
                    candidates: preloadCache.records,
                    title: track.title,
                    duration: track.duration
                )
            }
            resolveNonAlacFallback(from: track)
            clearCacheLookupSchedule()
            debugLog("format: preload cache miss after wait reason=\(reason); fallback \(debugFormat(cachedFormat)) status=\(cachedStatusDescription)")
            return
        }

        cachedFormat = nil
        cachedStatus = .detecting
        cachedFormatSource = nil
        cachedUnverifiedSampleRate = nil
        nextCacheRefreshAt = min(now.addingTimeInterval(emptyCacheRetryInterval), cacheLookupDeadline)
        debugLog("format: preload cache miss reason=\(reason); waiting for cache until \(debugTime(cacheLookupDeadline))")
    }

    private func clearCacheLookupSchedule() {
        firstCacheLookupAt = nil
        cacheLookupDeadline = nil
        nextCacheRefreshAt = nil
    }

    private func cacheRefreshDelay(now: Date) -> TimeInterval? {
        guard cachedStatus == .detecting,
              let nextCacheRefreshAt else {
            return nil
        }

        return max(0, nextCacheRefreshAt.timeIntervalSince(now))
    }

    private func rememberPreloadLogEntries(_ entries: [AppleMusicLogStream.Entry]) {
        var didChangeCache = false
        var didChangePlaybackFormat = false

        for entry in entries {
            if parser.parsePlaybackFormat(entry.message)?.codec == "ALAC" {
                didChangePlaybackFormat = promotePlaybackLosslessIfEligible(from: entry) || didChangePlaybackFormat
            }

            let completedRecords = preloadAssembler.ingest(
                message: entry.message,
                date: entry.date,
                parser: parser
            )

            for record in completedRecords {
                didChangeCache = rememberCompletedPreloadRecord(record) || didChangeCache
            }
        }

        if didChangeCache || didChangePlaybackFormat {
            preloadCacheDidChange?()
        }
    }

    @discardableResult
    private func promotePlaybackLosslessIfEligible(from entry: AppleMusicLogStream.Entry) -> Bool {
        guard let startedAt = currentTrackDetectionStartedAt else {
            return false
        }

        guard entry.date >= startedAt else {
            return false
        }

        let elapsed = entry.date.timeIntervalSince(startedAt)
        let allowedElapsed = playbackLosslessPromotionWindow + playbackLosslessPromotionDeliveryTolerance
        guard elapsed <= allowedElapsed else {
            debugLog("format: playback lossless ignored outside promotion window elapsed=\(elapsed)s limit=\(allowedElapsed)s")
            return false
        }

        if cachedFormatSource == .preloadCache || cachedFormatSource == .localFile || cachedFormat?.bitDepth != nil {
            debugLog("format: playback lossless ignored: authoritative format already available source=\(Self.debugOptional(cachedFormatSource)) \(debugFormat(cachedFormat))")
            return false
        }

        let track = currentTrack()
        guard !track.isStopped else {
            return false
        }

        if let observedIdentity = track.identity,
           let expectedIdentity = currentTrackIdentity,
           observedIdentity != expectedIdentity {
            debugLog("format: playback lossless ignored for stale track expected=\(Self.debugQuote(expectedIdentity)) observed=\(Self.debugQuote(observedIdentity))")
            return false
        }

        let sampleRate = track.sampleRate ?? currentTrackAppleScriptSampleRate
        guard let sampleRate else {
            debugLog("format: playback lossless ignored: missing AppleScript sampleRate")
            return false
        }

        let promotedFormat = AudioFormat(codec: "ALAC", sampleRate: sampleRate)
        guard cachedFormat != promotedFormat || cachedStatus != .detected || cachedFormatSource != .playbackLog else {
            return false
        }

        cachedFormat = promotedFormat
        cachedStatus = .detected
        cachedFormatSource = .playbackLog
        cachedUnverifiedSampleRate = nil
        currentTrackAppleScriptSampleRate = sampleRate
        clearCacheLookupSchedule()
        debugLog("format: playback lossless promoted elapsed=\(elapsed)s window=\(playbackLosslessPromotionWindow)s tolerance=\(playbackLosslessPromotionDeliveryTolerance)s sampleRate=\(sampleRate)")
        return true
    }

    private func refinePlaybackLogFormatFromPreloadCache(for track: TrackSnapshot) {
        lastResolvedPreloadCacheRevision = preloadCacheRevision

        guard case .found(let record) = preloadCache.lookup(title: track.title, duration: track.duration) else {
            return
        }

        let baseFormat = cachedFormat ?? AudioFormat(codec: "ALAC", sampleRate: currentTrackAppleScriptSampleRate ?? track.sampleRate)
        let resolvedFormat = baseFormat.merging(record.format)
        guard resolvedFormat.isReadyForDisplay else {
            return
        }

        cachedFormat = resolvedFormat
        cachedStatus = .detected
        cachedFormatSource = .preloadCache
        cachedUnverifiedSampleRate = nil
        debugLog("format: playback lossless refined from preload cache queueItemID=\(record.queueItemID) group=\(record.groupID) \(debugFormat(resolvedFormat))")
    }

    @discardableResult
    private func rememberCompletedPreloadRecord(_ record: AppleMusicPreloadRecord) -> Bool {
        let existingRecord = preloadCache.store(record)
        guard existingRecord != record else {
            return false
        }

        preloadCacheRevision += 1
        debugLog("preload: saved completed format queueItemID=\(record.queueItemID) title=\(Self.debugQuote(record.title)) group=\(record.groupID) parsed=\(debugFormat(record.format))")
        return true
    }

    private struct TrackSnapshot {
        var playerState: String?
        var persistentID: String?
        var title: String?
        var artist: String?
        var album: String?
        var kind: String?
        var bitRate: Int?
        var sampleRate: Double?
        var duration: Double?
        var playerPosition: Double?
        var localFilePath: String?

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

        var identity: String? {
            guard !isStopped else { return nil }
            return [persistentID, title, artist, album]
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

        var localFileURL: URL? {
            guard let localFilePath,
                  !localFilePath.isEmpty else {
                return nil
            }

            return URL(fileURLWithPath: localFilePath)
        }

        var kindSuggestsDownloadedAppleMusicFile: Bool {
            guard let kind else {
                return false
            }

            let lowercasedKind = kind.lowercased()
            return lowercasedKind.contains("apple music")
                && (lowercasedKind.contains("오디오 파일") || lowercasedKind.contains("audio file"))
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

    private func integerSeconds(_ value: Double) -> Int {
        Int(value)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        print("[isLossless] \(message())")
    }

    private func debugPreloadCacheLookupFailure(
        candidates: [AppleMusicPreloadRecord],
        title: String?,
        duration: Double?
    ) {
        guard !candidates.isEmpty else {
            debugLog("preload lookup failed: completed cache is empty")
            return
        }

        let titleMatches = title.map { targetTitle in
            candidates.filter { titlesMatch($0.title, targetTitle) }
        } ?? []
        let durationMatches = duration.map { targetDuration in
            candidates.filter { durationsMatch($0.duration, targetDuration) }
        } ?? []
        let titleOnlyMatches = titleMatches.filter { candidate in
            duration.map { !durationsMatch(candidate.duration, $0) } ?? true
        }
        let durationOnlyMatches = durationMatches.filter { candidate in
            title.map { !titlesMatch(candidate.title, $0) } ?? true
        }

        debugLog(
            "preload lookup: failed reason=no-exact-match completedCandidates=\(candidates.count) targetTitle=\(Self.debugQuote(title)) targetDurationInt=\(Self.debugDurationInt(duration)) titleMatches=\(titleMatches.count) durationMatches=\(durationMatches.count) titleOnly=\(titleOnlyMatches.count) durationOnly=\(durationOnlyMatches.count)"
        )

        if !titleOnlyMatches.isEmpty {
            debugLog("preload lookup title-only candidates: \(debugPreloadCandidates(titleOnlyMatches))")
        }

        if !durationOnlyMatches.isEmpty {
            debugLog("preload lookup duration-only candidates: \(debugPreloadCandidates(durationOnlyMatches))")
        }

        if titleOnlyMatches.isEmpty && durationOnlyMatches.isEmpty {
            debugLog("preload lookup recent candidates: \(debugPreloadCandidates(candidates))")
        }
    }

    private func debugPreloadCandidates(_ candidates: [AppleMusicPreloadRecord]) -> String {
        candidates
            .prefix(5)
            .map { "id=\($0.queueItemID) title=\(Self.debugQuote($0.title)) durationInt=\(integerSeconds($0.duration)) group=\($0.groupID) rawDuration=\($0.duration)" }
            .joined(separator: " | ")
    }

    private func debugFormat(_ format: AudioFormat?) -> String {
        guard let format else {
            return "-"
        }

        return "codec=\(Self.debugOptional(format.codec)) bitDepth=\(Self.debugOptional(format.bitDepth)) bitRate=\(Self.debugOptional(format.bitRate)) sampleRate=\(Self.debugOptional(format.sampleRate))"
    }

    private var cachedStatusDescription: String {
        Self.debugOptional(cachedStatus)
    }

    private func debugTime(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }

        return date.formatted(date: .omitted, time: .standard)
    }

    private static func debugQuote(_ value: String?) -> String {
        guard let value else {
            return "-"
        }

        return "\"\(value)\""
    }

    private static func debugOptional<T>(_ value: T?) -> String {
        guard let value else {
            return "-"
        }

        return "\(value)"
    }

    private static func debugDurationInt(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }

        return "\(Int(value))"
    }

    private func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.precomposedStringWithCanonicalMapping == rhs.precomposedStringWithCanonicalMapping
    }

    private func durationsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        integerSeconds(lhs) == integerSeconds(rhs)
    }

}

private final class AppleMusicLogStream: @unchecked Sendable {
    struct Entry: Sendable {
        let date: Date
        let message: String

        init(date: Date, message: String) {
            self.date = date
            self.message = message
        }

        init(event: AppleMusicLogEvent) {
            self.date = event.date
            self.message = event.message
        }
    }

    struct Snapshot: Sendable {
        let isRunning: Bool
        let entries: [Entry]
    }

    private let queue = DispatchQueue(label: "isLossless.apple-music-log-stream")
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var eventBuffer = AppleMusicLogEventBuffer()
    private var entries: [Entry] = []
    private var isRunning = false
    private let retentionInterval: TimeInterval = 300
    private let onEntries: ([Entry]) -> Void

    init(_ onEntries: @escaping ([Entry]) -> Void) {
        self.onEntries = onEntries
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    func snapshot(since date: Date) -> Snapshot {
        queue.sync {
            pruneEntries(now: Date())
            return Snapshot(
                isRunning: isRunning,
                entries: entriesForSnapshot(since: date)
            )
        }
    }

    private func startOnQueue() {
        guard process == nil else {
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            "--level", "debug",
            "--predicate", Self.predicate
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendOutput(data)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else {
                return
            }
            print("[isLossless] log stream stderr: \(message)")
        }

        process.terminationHandler = { [weak self] process in
            guard let logStream = self else { return }
            logStream.queue.async {
                logStream.isRunning = false
                logStream.process = nil
                logStream.outputPipe = nil
                logStream.errorPipe = nil
                print("[isLossless] log stream exited status=\(process.terminationStatus)")
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            isRunning = true
            print("[isLossless] log stream started")
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            isRunning = false
            print("[isLossless] log stream failed to start: \(error.localizedDescription)")
        }
    }

    private func stopOnQueue() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        outputPipe = nil
        errorPipe = nil
        isRunning = false
        eventBuffer.reset()
    }

    private func appendOutput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }

        queue.async { [weak self] in
            self?.consume(text)
        }
    }

    private func consume(_ text: String) {
        let newEntries = eventBuffer.ingest(text, date: Date()).map(Entry.init(event:))
        guard !newEntries.isEmpty else {
            return
        }

        entries.append(contentsOf: newEntries)
        pruneEntries(now: Date())
        onEntries(newEntries)
    }

    private func entriesForSnapshot(since date: Date) -> [Entry] {
        var snapshotEntries = entries.filter { $0.date >= date }
        if let currentEntry = eventBuffer.currentEntry(),
           currentEntry.date >= date {
            snapshotEntries.append(Entry(event: currentEntry))
        }
        return snapshotEntries
    }

    private func pruneEntries(now: Date) {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        entries.removeAll { $0.date < cutoff }
    }

    private static let predicate = """
    process == "Music" AND (subsystem == "com.apple.amp.mediaplaybackcore" OR eventMessage CONTAINS[c] "item-begin" OR eventMessage CONTAINS[c] "audio-format-changed" OR eventMessage CONTAINS[c] "PlaybackEventStream" OR eventMessage CONTAINS[c] "Engagement" OR eventMessage CONTAINS[c] "PBAudioFormat" OR eventMessage CONTAINS[c] "Audio format changed")
    """
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
        let resolvedCodec = codec ?? other?.codec

        return AudioFormat(
            codec: resolvedCodec,
            bitDepth: bitDepth,
            bitRate: resolvedCodec == "ALAC" ? nil : (other?.bitRate ?? bitRate),
            sampleRate: other?.sampleRate ?? sampleRate
        )
    }

    func fillingMissingFields(from other: AudioFormat?) -> AudioFormat {
        let resolvedCodec = codec ?? other?.codec

        return AudioFormat(
            codec: resolvedCodec,
            bitDepth: bitDepth ?? other?.bitDepth,
            bitRate: resolvedCodec == "ALAC" ? nil : (bitRate ?? other?.bitRate),
            sampleRate: sampleRate ?? other?.sampleRate
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

    var isReadyForDisplay: Bool {
        switch codec {
        case "ALAC":
            return sampleRate != nil
        case "AAC":
            return true
        default:
            return !isEmpty
        }
    }
}

final class LocalAudioFormatReader {
    func format(for url: URL) -> Result<AudioFormat, Error> {
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard openStatus == noErr, let audioFile else {
            return .failure(LocalAudioFormatError.openFailed(openStatus))
        }
        defer {
            AudioFileClose(audioFile)
        }

        var description = AudioStreamBasicDescription()
        var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let descriptionStatus = AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyDataFormat,
            &descriptionSize,
            &description
        )
        guard descriptionStatus == noErr else {
            return .failure(LocalAudioFormatError.dataFormatUnavailable(descriptionStatus))
        }

        let codec = codecName(for: description.mFormatID)
        let bitDepth = description.mBitsPerChannel > 0 ? Int(description.mBitsPerChannel) : nil
        let sampleRate = description.mSampleRate > 0 ? description.mSampleRate : nil
        let bitRate = bitRate(for: audioFile)
        let format = AudioFormat(
            codec: codec,
            bitDepth: bitDepth,
            bitRate: bitRate,
            sampleRate: sampleRate
        )

        guard codec != nil,
              format.isReadyForDisplay else {
            return .failure(LocalAudioFormatError.unsupportedFormat(Self.fourCharacterCode(description.mFormatID)))
        }

        return .success(format)
    }

    private func codecName(for formatID: AudioFormatID) -> String? {
        if formatID == kAudioFormatAppleLossless {
            return "ALAC"
        }

        let fourCC = Self.fourCharacterCode(formatID).lowercased()
        if fourCC.contains("aac") || formatID == kAudioFormatMPEG4AAC {
            return "AAC"
        }

        return nil
    }

    private func bitRate(for audioFile: AudioFileID) -> Int? {
        var bitRate = UInt32()
        var bitRateSize = UInt32(MemoryLayout<UInt32>.size)
        let bitRateStatus = AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyBitRate,
            &bitRateSize,
            &bitRate
        )

        guard bitRateStatus == noErr, bitRate > 0 else {
            return nil
        }

        return Int((Double(bitRate) / 1_000).rounded())
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(value)"
    }

    private enum LocalAudioFormatError: LocalizedError {
        case openFailed(OSStatus)
        case dataFormatUnavailable(OSStatus)
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let status):
                return "AudioFileOpenURL failed status=\(status)"
            case .dataFormatUnavailable(let status):
                return "AudioFileGetProperty data format failed status=\(status)"
            case .unsupportedFormat(let formatID):
                return "Unsupported local audio format id=\(formatID)"
            }
        }
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

private extension UInt32 {
    var nonZeroInt: Int? {
        self > 0 ? Int(self) : nil
    }
}

struct AudioOutputSnapshot: Sendable {
    let sampleRate: Double?
    let bitDepth: Int?
}

final class AudioOutputReader {
    func currentOutput() -> AudioOutputSnapshot {
        guard let deviceID = defaultOutputDeviceID() else {
            return AudioOutputSnapshot(sampleRate: nil, bitDepth: nil)
        }

        return AudioOutputSnapshot(
            sampleRate: nominalSampleRate(for: deviceID),
            bitDepth: outputBitDepth(for: deviceID)
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

    private func outputBitDepth(for deviceID: AudioDeviceID) -> Int? {
        outputStreamIDs(for: deviceID)
            .compactMap(streamBitDepth)
            .max()
    }

    private func outputStreamIDs(for deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioStreamID>.size else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: count)
        let status = streams.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(kAudioHardwareBadObjectError)
            }

            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, baseAddress)
        }

        return status == noErr ? streams : []
    }

    private func streamBitDepth(for streamID: AudioStreamID) -> Int? {
        streamFormat(for: streamID, selector: kAudioStreamPropertyPhysicalFormat)?.mBitsPerChannel.nonZeroInt
            ?? streamFormat(for: streamID, selector: kAudioStreamPropertyVirtualFormat)?.mBitsPerChannel.nonZeroInt
    }

    private func streamFormat(for streamID: AudioStreamID, selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &description)

        return status == noErr ? description : nil
    }
}

final class AudioOutputObserver {
    private var onChange: (() -> Void)?
    private var isObservingDefaultOutput = false
    private var observedSampleRateDeviceID: AudioDeviceID?

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange

        var address = Self.defaultOutputDeviceAddress
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.defaultOutputChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        isObservingDefaultOutput = status == noErr
        updateSampleRateObserver()
    }

    func stop() {
        if isObservingDefaultOutput {
            var address = Self.defaultOutputDeviceAddress
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                Self.defaultOutputChanged,
                Unmanaged.passUnretained(self).toOpaque()
            )
            isObservingDefaultOutput = false
        }

        removeSampleRateObserver()
        onChange = nil
    }

    private func outputDidChange() {
        updateSampleRateObserver()
        onChange?()
    }

    private func sampleRateDidChange() {
        onChange?()
    }

    private func updateSampleRateObserver() {
        removeSampleRateObserver()

        guard let deviceID = Self.defaultOutputDeviceID() else {
            return
        }

        var address = Self.nominalSampleRateAddress
        let status = AudioObjectAddPropertyListener(
            deviceID,
            &address,
            Self.sampleRateChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            observedSampleRateDeviceID = deviceID
        }
    }

    private func removeSampleRateObserver() {
        guard let deviceID = observedSampleRateDeviceID else {
            return
        }

        var address = Self.nominalSampleRateAddress
        AudioObjectRemovePropertyListener(
            deviceID,
            &address,
            Self.sampleRateChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        observedSampleRateDeviceID = nil
    }

    private static let defaultOutputChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else {
            return noErr
        }

        Unmanaged<AudioOutputObserver>.fromOpaque(context).takeUnretainedValue().outputDidChange()
        return noErr
    }

    private static let sampleRateChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else {
            return noErr
        }

        Unmanaged<AudioOutputObserver>.fromOpaque(context).takeUnretainedValue().sampleRateDidChange()
        return noErr
    }

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var nominalSampleRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = defaultOutputDeviceAddress
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
