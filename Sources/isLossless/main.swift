#if os(macOS)
import AppKit
import CoreAudio
import Foundation
import IsLosslessCore
import OSLog
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
    private var previousTrackIdentity: String?
    private var followUpRefreshWorkItems: [DispatchWorkItem] = []
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
        static let actionRowHeight: CGFloat = 26
        static let headerFontSize: CGFloat = 14
        static let bodyFontSize: CGFloat = 13
        static let analysisIconTextGap: CGFloat = 6

        static var contentWidth: CGFloat {
            width - horizontalInset * 2
        }

        static var analysisColumnWidth: CGFloat {
            (contentWidth - columnSpacing) / 2
        }

        static var analysisSingleColumnWidth: CGFloat {
            contentWidth
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
        configureMenu()
        updateMenuBarTitle()
        observeAppleMusicChanges()
        observeAudioOutputChanges()
        refresh()
        print("isLosslessTest is running. Look for the waveform icon in the macOS menu bar.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        outputObserver.stop()
    }

    @objc private func refresh() {
        refresh(forceLogScan: false)
    }

    @objc private func manualRefresh() {
        applyState(monitor.prepareManualRefresh())
        DispatchQueue.main.async { [weak self] in
            self?.refresh(forceLogScan: true)
        }
    }

    private func refresh(forceLogScan: Bool) {
        applyState(monitor.snapshot(forceLogScan: forceLogScan))
        if !forceLogScan {
            scheduleFollowUpRefreshesIfNeeded()
        }
    }

    private func applyState(_ newState: AppState) {
        let oldLayoutIdentity = state.menuLayoutIdentity
        state = newState
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
        newState.outputDeviceName = output.name
        newState.outputSampleRate = output.sampleRate
        applyState(newState)
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem.button else {
            print("isLossless could not create a menu bar button.")
            return
        }

        if let icon = iconProvider.icon(for: state.format),
           let detail = iconProvider.detailText(for: state.format, formatter: formatter) {
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let title = iconProvider.titleBeforeIcon(for: detail)
            statusItem.length = iconProvider.itemLength(for: icon, title: title, font: button.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            button.title = title
            button.image = icon
            button.imagePosition = .imageRight
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = nil
        } else {
            let title = formatter.title(for: state.format, status: state.status)
            if iconProvider.shouldUseInactiveIcon(for: title), let icon = iconProvider.inactiveIcon {
                statusItem.length = iconProvider.iconOnlyItemLength(for: icon)
                button.title = ""
                button.image = icon
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.contentTintColor = nil
            } else {
                statusItem.length = NSStatusItem.variableLength
                button.image = nil
                button.title = title
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
        menuSlidingTextViews.removeAll()
        synchronizedSlidingGroups.removeAll()
        menuImageViews.removeAll()

        menu.addItem(headerItem())
        menu.addItem(analysisItem())
        menu.addItem(.separator())
        menu.addItem(informationalItem("출력", key: "output-title", secondary: true, compact: true))
        menu.addItem(informationalItem(outputText, key: "output", emphasized: false, compact: true))
        menu.addItem(.separator())
        menu.addItem(refreshMenuItem())
        menu.addItem(actionMenuItem(
            title: "종료",
            systemSymbolName: "xmark.square",
            shortcut: "⌘Q",
            target: NSApp,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    private func updateMenuLabels() {
        menuLabels["analysis-line-1"]?.stringValue = analysisStatusText
        menuSlidingTextViews["analysis-detail"]?.stringValue = analysisDetailText
        menuSlidingTextViews["track-title"]?.stringValue = trackTitleText
        menuSlidingTextViews["track-artist"]?.stringValue = artistText
        synchronizedSlidingGroups["track-metadata"]?.restart()
        menuImageViews["analysis-detail-icon"]?.image = analysisDetailIcon
        menuLabels["output"]?.stringValue = outputText
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

    private func refreshMenuItem() -> NSMenuItem {
        actionMenuItem(
            title: "새로 고침",
            systemSymbolName: "arrow.clockwise",
            shortcut: "⌘R",
            target: self,
            action: #selector(manualRefresh),
            keyEquivalent: "r"
        )
    }

    private func actionMenuItem(
        title: String,
        systemSymbolName: String,
        shortcut: String,
        target: AnyObject?,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.view = menuItemView(
            arrangedSubviews: [
                MenuActionRowView(
                    title: title,
                    systemSymbolName: systemSymbolName,
                    shortcut: shortcut,
                    width: MenuLayout.contentWidth,
                    height: MenuLayout.actionRowHeight,
                    fontSize: MenuLayout.bodyFontSize,
                    target: target,
                    action: action
                )
            ],
            topInset: 1,
            bottomInset: 1
        )
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

        for delay in [1.0, 3.0] {
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.refresh(forceLogScan: false)
                }
            }
            followUpRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private var analysisStatusText: String {
        state.statusText
    }

    private var outputText: String {
        let sampleRateText: String?
        if state.format?.codec == "ALAC",
           let sourceSampleRate = state.format?.sampleRate,
           let outputSampleRate = state.outputSampleRate {
            sampleRateText = "\(formatter.formatSampleRate(sourceSampleRate)) → \(formatter.formatSampleRate(outputSampleRate))"
        } else {
            sampleRateText = state.outputSampleRate.map(formatter.formatSampleRate)
        }

        let text = [state.outputDeviceName, sampleRateText]
            .compactMap { $0 }
            .joined(separator: " · ")
        return text.isEmpty ? "—" : text
    }

    private var analysisDetailText: String {
        guard hasCurrentTrack else {
            return "—"
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

        if state.status != .detecting {
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
            return format?.bitRate.map { "\($0)kbps" }
        default:
            return nil
        }
    }

    func titleBeforeIcon(for detail: String) -> String {
        "\(detail)  "
    }

    func itemLength(for icon: NSImage, title: String, font: NSFont) -> CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        return max(24, (icon.size.width + textWidth + 8).rounded(.up))
    }

    func shouldUseInactiveIcon(for title: String) -> Bool {
        title == "—" || title == "isLossless"
    }

    func iconOnlyItemLength(for icon: NSImage) -> CGFloat {
        max(24, icon.size.width + 6)
    }

    private static func loadIcon(named name: String, targetHeight: CGFloat) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        let aspectRatio = image.size.width / image.size.height
        image.size = NSSize(width: (targetHeight * aspectRatio).rounded(), height: targetHeight)
        image.isTemplate = true
        return image
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
    var outputDeviceName: String?
    var outputSampleRate: Double?

    var menuLayoutIdentity: String {
        trackTitle != nil || artistName != nil || albumName != nil ? "analysis-two-column" : "analysis-single-column"
    }

    var statusText: String {
        switch playbackStatus {
        case .playing: "재생 중"
        case .paused: "일시 정지"
        case .stopped: "재생 중이 아님"
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
    private var pendingLogScanAttempts = 0
    private var nextLogScanAt: Date?

    func currentOutput() -> AudioOutputSnapshot {
        outputReader.currentOutput()
    }

    func prepareManualRefresh() -> AppState {
        guard isAppleMusicRunning else {
            resetPlaybackTracking()
            return AppState(status: .appleMusicNotRunning, playbackStatus: .notRunning)
        }

        let track = currentTrack()
        cachedFormat = nil
        stopLogScanPlan()

        if track.isStopped {
            resetPlaybackTracking()
        } else {
            currentTrackIdentity = track.identity
            currentTrackStartedAt = track.startedAt ?? Date().addingTimeInterval(-8)
        }

        return makeState(for: track, format: nil)
    }

    func snapshot(forceLogScan: Bool = false) -> AppState {
        guard isAppleMusicRunning else {
            resetPlaybackTracking()
            return AppState(status: .appleMusicNotRunning, playbackStatus: .notRunning)
        }

        let track = currentTrack()
        if track.isStopped {
            resetPlaybackTracking()
        } else if track.identity != currentTrackIdentity {
            cachedFormat = nil
            currentTrackIdentity = track.identity
            currentTrackStartedAt = track.startedAt ?? Date().addingTimeInterval(-8)
            startAutomaticLogScanPlan()
        } else if cachedFormat != nil {
            cachedFormat = cachedFormat?.preservingBitDepth(from: track.format) ?? track.format
        }

        if forceLogScan, !track.isStopped {
            cachedFormat = nil
            currentTrackStartedAt = track.startedAt ?? Date().addingTimeInterval(-8)
            startManualLogScanAttempt()
        }

        if let isFinalLogScanAttempt = consumeDueLogScanAttempt() {
            if let latestFormat = latestFormatFromLogs(since: currentTrackStartedAt) {
                let resolvedFormat = track.format?.merging(latestFormat) ?? latestFormat
                if resolvedFormat.isReadyForDisplay {
                    cachedFormat = resolvedFormat
                }
                stopLogScanPlan()
            } else if isFinalLogScanAttempt {
                cachedFormat = fallbackAACFormat(from: track)
            }
        }

        return makeState(for: track, format: cachedFormat)
    }

    private func resetPlaybackTracking() {
        cachedFormat = nil
        currentTrackIdentity = nil
        currentTrackStartedAt = nil
        stopLogScanPlan()
    }

    private func startAutomaticLogScanPlan() {
        pendingLogScanAttempts = 2
        nextLogScanAt = Date().addingTimeInterval(1)
    }

    private func startManualLogScanAttempt() {
        pendingLogScanAttempts = 1
        nextLogScanAt = Date()
    }

    private func stopLogScanPlan() {
        pendingLogScanAttempts = 0
        nextLogScanAt = nil
    }

    private func consumeDueLogScanAttempt() -> Bool? {
        guard pendingLogScanAttempts > 0 else {
            return nil
        }

        guard let nextLogScanAt, Date() >= nextLogScanAt else {
            return nil
        }

        let isFinalAttempt = pendingLogScanAttempts == 1
        pendingLogScanAttempts -= 1
        self.nextLogScanAt = pendingLogScanAttempts > 0 ? Date().addingTimeInterval(2) : nil
        return isFinalAttempt
    }

    private func fallbackAACFormat(from track: TrackSnapshot) -> AudioFormat? {
        let format = AudioFormat(
            codec: "AAC",
            bitRate: track.bitRate,
            sampleRate: track.sampleRate
        )
        return format.isReadyForDisplay ? format : nil
    }

    private func makeState(for track: TrackSnapshot, format: AudioFormat?) -> AppState {
        let output = outputReader.currentOutput()
        var state = AppState(
            status: format == nil ? .detecting : .detected,
            playbackStatus: track.playbackStatus,
            format: format,
            trackIdentity: track.identity,
            trackTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
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
                set trackPosition to player position as text
            end try
            return playerState & fieldDelimiter & trackID & fieldDelimiter & trackName & fieldDelimiter & artistName & fieldDelimiter & albumName & fieldDelimiter & trackKind & fieldDelimiter & trackBitRate & fieldDelimiter & trackSampleRate & fieldDelimiter & trackPosition
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
            sampleRate: parts.nonEmptyValue(at: 7).flatMap(Double.init),
            playerPosition: parts.nonEmptyValue(at: 8).flatMap(Double.init)
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
        let predicate = NSPredicate(
            format: "process == %@ AND eventMessage CONTAINS[c] %@",
            "Music",
            "Audio format changed to PBAudioFormat."
        )
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return nil
        }

        let logEntries = entries
            .compactMap { $0 as? OSLogEntryLog }
            .reversed()

        for entry in logEntries {
            if let format = parser.parsePlaybackFormat(entry.composedMessage) {
                return format
            }
        }

        return nil
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

    var isReadyForDisplay: Bool {
        switch codec {
        case "ALAC":
            return sampleRate != nil
        case "AAC":
            return bitRate != nil
        default:
            return !isEmpty
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
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanagedName)

        guard status == noErr, let unmanagedName else {
            return nil
        }

        return unmanagedName.takeRetainedValue() as String
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

final class MenuActionRowView: NSView {
    private let target: AnyObject?
    private let action: Selector
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var isPressing = false {
        didSet { needsDisplay = true }
    }

    init(
        title: String,
        systemSymbolName: String,
        shortcut: String,
        width: CGFloat,
        height: CGFloat,
        fontSize: CGFloat,
        target: AnyObject?,
        action: Selector
    ) {
        self.target = target
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: title)
        iconView.image?.isTemplate = true
        iconView.contentTintColor = .labelColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: fontSize, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = .systemFont(ofSize: fontSize, weight: .regular)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -10),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovering || isPressing else {
            return
        }

        let alpha: CGFloat = isPressing ? 0.34 : 0.22
        NSColor.separatorColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: -4, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressing = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldPerformAction = isPressing && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressing = false
        if shouldPerformAction {
            NSApp.sendAction(action, to: target, from: self)
        }
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
