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
    private var menuIndicatorViews: [String: NSView] = [:]
    private var menuBarContentView: MenuBarStatusContentView?
    private var isMenuOpen = false
    private var pendingCacheRefreshWorkItem: DispatchWorkItem?
    private var pendingOutputRefreshWorkItem: DispatchWorkItem?
    private var pendingOutputSwitchSettlingWorkItem: DispatchWorkItem?
    private var isOutputSwitchSettling = false
    private let outputObserver = AudioOutputObserver()
    private let outputSwitchCoordinator = AutomaticOutputSwitchCoordinator()
    private let predictionCoordinator = PreloadPredictionCoordinator()

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
        monitor.preloadCacheDidChange = { [weak self] changes in
            self?.handlePreloadCacheChanges(changes)
        }
        predictionCoordinator.onPendingStateChanged = { [weak self] isPending in
            self?.setOutputPredictionPending(isPending)
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
        pendingOutputRefreshWorkItem?.cancel()
        pendingOutputSwitchSettlingWorkItem?.cancel()
        predictionCoordinator.cancel(reason: "app-terminating")
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

    private func handlePreloadCacheChanges(_ changes: [PreloadCacheChange]) {
        for change in changes {
            if case .queueSnapshot(let result) = change {
                predictionCoordinator.cancelIfPendingReordered(result)
            }
        }

        if changes.contains(where: shouldRefreshAfterPreloadChange) {
            refresh(forceLogScan: false)
        }

        if changes.contains(where: shouldApplyEventPredictionAfterPreloadChange) {
            applyEventPredictionIfPossible()
        }
    }

    private func shouldRefreshAfterPreloadChange(_ change: PreloadCacheChange) -> Bool {
        switch change {
        case .playbackFormatPromoted:
            return true

        case .currentQueueFormatResolved:
            return true

        case .playbackTick, .queueLink, .queueSnapshot:
            return false

        case .savedFormatOnly(let record):
            return isPotentialNextPreloadRecord(record)

        case .enrichedMetadata(let record), .savedCompleted(let record):
            return isCurrentOrNextPreloadRecord(record)
                || matchesCurrentTrackMetadata(record)
                || isPotentialNextPreloadRecord(record)
        }
    }

    private func shouldApplyEventPredictionAfterPreloadChange(_ change: PreloadCacheChange) -> Bool {
        switch change {
        case .playbackTick, .queueLink, .queueSnapshot, .currentQueueFormatResolved, .savedFormatOnly:
            return true
        case .enrichedMetadata, .savedCompleted, .playbackFormatPromoted:
            return false
        }
    }

    private func isCurrentOrNextPreloadRecord(_ record: AppleMusicPreloadRecord) -> Bool {
        record.queueItemID == state.currentPreloadRecord?.queueItemID
            || record.queueItemID == state.nextPreloadRecord?.queueItemID
    }

    private func isPotentialNextPreloadRecord(_ record: AppleMusicPreloadRecord) -> Bool {
        guard let currentRecord = state.currentPreloadRecord,
              record.queueItemID > currentRecord.queueItemID else {
            return false
        }

        if let currentSectionID = currentRecord.queueSectionID,
           record.queueSectionID != currentSectionID {
            return false
        }

        if let nextRecord = state.nextPreloadRecord {
            return record.queueItemID <= nextRecord.queueItemID
        }

        return true
    }

    private func matchesCurrentTrackMetadata(_ record: AppleMusicPreloadRecord) -> Bool {
        guard let recordTitle = record.title,
              let recordDuration = record.duration,
              let trackTitle = state.trackTitle,
              let trackDuration = state.trackDuration else {
            return false
        }

        return recordTitle.precomposedStringWithCanonicalMapping == trackTitle.precomposedStringWithCanonicalMapping
            && Int(recordDuration) == Int(trackDuration)
    }

    private func applyState(_ newState: AppState) {
        let oldLayoutIdentity = state.menuLayoutIdentity
        state = newState
        predictionCoordinator.observeState(state.predictionState)
        let outputSwitchSuppressionFields = monitor.outputSwitchSuppressionFields(for: state)
        let shouldDeferOutputSwitch = outputSwitchSuppressionFields == nil
            && predictionCoordinator.shouldDeferOutputSwitch(for: state.predictionState)

        if let suppressionFields = outputSwitchSuppressionFields {
            print("[isLossless] output.switch action=skipped \(suppressionFields)")
        } else if !shouldDeferOutputSwitch {
            let result = outputSwitchCoordinator.applyIfNeeded(for: state)
            beginOutputSwitchSettlingIfNeeded(result)
            refreshOutputAfterSwitchIfNeeded(result)
        }
        state.hasPendingOutputPrediction = predictionCoordinator.hasPendingPrediction
        state.hasMatchingOutputPrediction = !state.hasPendingOutputPrediction
            && isMatchingFormatPredictionAvailable(for: state.predictionState)
        state.isStatusMarkerTransitioning = outputSwitchSuppressionFields != nil
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

    private func applyEventPredictionIfPossible() {
        let eventState = monitor.eventPredictionState()
        _ = predictionCoordinator.applyEventPrediction(
            for: eventState,
            validate: { [weak self] in
                self?.monitor.eventPredictionState() ?? PreloadPredictionState(playbackState: .notRunning)
            }
        ) { [weak self] record, trackIdentity, previousQueueItemID in
            self?.applyPredictionOutput(
                record,
                trackIdentity: trackIdentity,
                previousQueueItemID: previousQueueItemID
            )
        }
        setOutputPredictionPending(
            predictionCoordinator.hasPendingPrediction,
            predictionState: eventState
        )
    }

    private func setOutputPredictionPending(
        _ isPending: Bool,
        predictionState: PreloadPredictionState? = nil
    ) {
        let isMatching = !isPending
            && isMatchingFormatPredictionAvailable(for: predictionState ?? state.predictionState)
        guard state.hasPendingOutputPrediction != isPending
                || state.hasMatchingOutputPrediction != isMatching else {
            updateOutputPredictionIndicator()
            updateMenuBarTitle()
            return
        }

        state.hasPendingOutputPrediction = isPending
        state.hasMatchingOutputPrediction = isMatching
        updateOutputPredictionIndicator()
        updateMenuBarTitle()
    }

    private func isMatchingFormatPredictionAvailable(for predictionState: PreloadPredictionState) -> Bool {
        guard predictionState.playbackState == .playing,
              let currentFormat = predictionState.currentRecord?.format,
              let nextFormat = predictionState.nextRecord?.format else {
            return false
        }

        return currentFormat.sampleRate == nextFormat.sampleRate
            && currentFormat.bitDepth == nextFormat.bitDepth
    }

    private func applyPredictionOutput(
        _ record: AppleMusicPreloadRecord,
        trackIdentity: String?,
        previousQueueItemID: Int
    ) -> AudioOutputSwitchResult? {
        let result = outputSwitchCoordinator.applyPrediction(
            format: record.format,
            trackIdentity: trackIdentity,
            queueItemID: record.queueItemID
        )
        if result?.shouldRefreshOutputSnapshot == true {
            monitor.rememberAppliedPrediction(
                record,
                previousTrackIdentity: trackIdentity,
                previousQueueItemID: previousQueueItemID
            )
        }
        beginOutputSwitchSettlingIfNeeded(result)
        refreshOutputAfterSwitchIfNeeded(result)
        return result
    }

    private func refreshOutputAfterSwitchIfNeeded(_ result: AudioOutputSwitchResult?) {
        guard let result,
              result.shouldRefreshOutputSnapshot else {
            return
        }

        refreshOutputSnapshot()

        pendingOutputRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshOutputSnapshot()
            }
        }
        pendingOutputRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func beginOutputSwitchSettlingIfNeeded(_ result: AudioOutputSwitchResult?) {
        guard result?.didApplyOutputChange == true else {
            return
        }

        isOutputSwitchSettling = true
        pendingOutputSwitchSettlingWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.isOutputSwitchSettling = false
                self.updateMenuBarTitle()
            }
        }
        pendingOutputSwitchSettlingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func refreshOutputSnapshot() {
        let output = monitor.currentOutput()
        guard output.sampleRate != state.outputSampleRate
            || output.bitDepth != state.outputBitDepth else {
            return
        }

        state.outputSampleRate = output.sampleRate
        state.outputBitDepth = output.bitDepth
        updateMenuBarTitle()

        if isMenuOpen {
            updateMenuLabels()
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

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let marker = currentMenuBarStatusMarker()

        if state.status == .unverifiedLossless,
           let icon = iconProvider.inactiveIcon {
            let title = state.unverifiedSampleRate.map(formatter.formatSampleRate) ?? ""
            configureMenuBarButton(button, title: title, icon: icon, marker: marker, font: font)
        } else if let icon = iconProvider.icon(for: state.format),
           let detail = iconProvider.detailText(for: state.format, formatter: formatter) {
            configureMenuBarButton(button, title: detail, icon: icon, marker: marker, font: font)
        } else {
            let title = formatter.title(for: state.format, status: state.status)
            let shouldUseInactiveIcon = iconProvider.shouldUseInactiveIcon(for: title)
            let icon = shouldUseInactiveIcon ? iconProvider.inactiveIcon : nil
            let shouldHideInactiveTitle = shouldUseInactiveIcon
                && icon != nil
                && (marker == .none || state.status == .failed)
            let displayTitle = shouldHideInactiveTitle ? "" : title
            configureMenuBarButton(button, title: displayTitle, icon: icon, marker: marker, font: font)
        }
        button.toolTip = state.accessibilityDescription
    }

    private func currentMenuBarStatusMarker() -> MenuBarStatusMarker {
        MenuBarStatusMarkerPolicy.marker(
            detectionStatus: state.status,
            currentFormat: state.format,
            outputSampleRate: state.outputSampleRate,
            outputBitDepth: state.outputBitDepth,
            isTransitioning: isMenuBarStatusMarkerTransitioning
        )
    }

    private var isMenuBarStatusMarkerTransitioning: Bool {
        state.isStatusMarkerTransitioning
            || isOutputSwitchSettling
    }

    private func configureMenuBarButton(
        _ button: NSStatusBarButton,
        title: String,
        icon: NSImage?,
        marker: MenuBarStatusMarker,
        font: NSFont
    ) {
        button.font = font
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        if let icon {
            let contentView = menuBarStatusContentView(for: button)
            contentView.configure(title: title, icon: icon, marker: marker, font: font)
            statusItem.length = ceil(contentView.fittingSize.width)
            button.image = nil
            button.imagePosition = .noImage
        } else {
            menuBarContentView?.removeFromSuperview()
            menuBarContentView = nil
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.title = title
            button.imagePosition = .noImage
        }
        button.imageHugsTitle = true
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = nil
    }

    private func menuBarStatusContentView(for button: NSStatusBarButton) -> MenuBarStatusContentView {
        if let menuBarContentView,
           menuBarContentView.superview === button {
            return menuBarContentView
        }

        let contentView = MenuBarStatusContentView()
        button.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            contentView.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        menuBarContentView = contentView
        return contentView
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
        menuIndicatorViews.removeAll()

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
        menuLabels["format-title"]?.stringValue = formatTitleText
        menuSlidingTextViews["format-detail"]?.stringValue = formatText
        menuLabels["output-detail"]?.stringValue = outputText
        updateOutputPredictionIndicator()
    }

    private func updateOutputPredictionIndicator() {
        guard let indicator = menuIndicatorViews["output-prediction-dot"] else {
            return
        }

        applyOutputPredictionIndicatorStyle(to: indicator)
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
            title: formatTitleText,
            detail: formatText,
            titleKey: "format-title",
            detailKey: "format-detail",
            width: MenuLayout.formatOutputFormatColumnWidth,
            slidesDetail: true
        )
        let outputColumn = twoLineInfoColumn(
            title: "출력",
            detail: outputText,
            titleKey: "output-title",
            detailKey: "output-detail",
            width: MenuLayout.analysisColumnWidth,
            indicatorKey: "output-prediction-dot"
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

    private func twoLineInfoColumn(
        title: String,
        detail: String,
        titleKey: String,
        detailKey: String,
        width: CGFloat,
        slidesDetail: Bool = false,
        indicatorKey: String? = nil
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        menuLabels[titleKey] = titleLabel

        let titleView: NSView
        if let indicatorKey {
            let indicator = predictionIndicatorView()
            applyOutputPredictionIndicatorStyle(to: indicator)
            menuIndicatorViews[indicatorKey] = indicator

            let titleStack = NSStackView(views: [titleLabel, indicator])
            titleStack.orientation = .horizontal
            titleStack.alignment = .centerY
            titleStack.spacing = 5
            titleView = titleStack
        } else {
            titleView = titleLabel
        }

        let detailView: NSView
        if slidesDetail {
            let slidingText = SlidingTextView(
                width: width,
                height: MenuLayout.analysisDetailRowHeight,
                font: .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .regular),
                textColor: .labelColor
            )
            slidingText.stringValue = detail
            menuSlidingTextViews[detailKey] = slidingText
            detailView = slidingText
        } else {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: MenuLayout.bodyFontSize, weight: .regular)
            detailLabel.textColor = .labelColor
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.maximumNumberOfLines = 1
            menuLabels[detailKey] = detailLabel
            detailView = detailLabel
        }

        let column = NSStackView(views: [
            fixedHeightRow(containing: titleView, width: width),
            fixedHeightRow(containing: detailView, width: width)
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MenuLayout.lineSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        return column
    }

    private func predictionIndicatorView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 7),
            view.heightAnchor.constraint(equalToConstant: 7)
        ])
        return view
    }

    private func applyOutputPredictionIndicatorStyle(to view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 3.5

        if state.hasPendingOutputPrediction {
            view.isHidden = false
            view.layer?.backgroundColor = NSColor.systemBlue.cgColor
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
        } else if state.hasMatchingOutputPrediction {
            view.isHidden = false
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.borderWidth = 1.25
            view.layer?.borderColor = NSColor.systemBlue.cgColor
        } else {
            view.isHidden = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
        }
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

    private var formatTitleText: String {
        if hasCurrentTrack,
           state.status == .failed {
            return "알 수 없음"
        }

        guard hasCurrentTrack,
              state.status == .detected,
              let codec = state.format?.codec else {
            return "—"
        }

        switch codec {
        case "ALAC", "AAC":
            return codec
        default:
            return "—"
        }
    }

    private var formatText: String {
        if hasCurrentTrack,
           state.status == .failed {
            return "정보를 불러오려면 다른 곡을 재생하거나 이 곡을 다시 재생하십시오."
        }

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

private extension MarkerColor {
    var nsColor: NSColor {
        switch self {
        case .green:
            return .systemGreen
        case .yellow:
            return .systemYellow
        case .red:
            return .systemRed
        }
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

private extension AudioOutputSwitchResult {
    var didApplyOutputChange: Bool {
        switch self {
        case .applied:
            return true
        case .alreadyMatched, .failed:
            return false
        }
    }
}

private final class MenuBarStatusContentView: NSView {
    private enum Layout {
        static let componentTopPadding: CGFloat = 1
        static let trailingPadding: CGFloat = 1
        static let textIconSpacing: CGFloat = 5
        static let textBottomPadding: CGFloat = 1
        static let markerTopPadding: CGFloat = 0.5
        static let markerDiameter: CGFloat = 7
        static let markerTrailingGap: CGFloat = 4
    }

    private let markerPaddingView = NSView()
    private let markerView = MenuBarMarkerView()
    private let textPaddingView = NSView()
    private let textField = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let stackView = NSStackView()
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField.setContentHuggingPriority(.required, for: .horizontal)

        textPaddingView.translatesAutoresizingMaskIntoConstraints = false
        textPaddingView.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: textPaddingView.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: textPaddingView.trailingAnchor),
            textField.topAnchor.constraint(equalTo: textPaddingView.topAnchor),
            textField.bottomAnchor.constraint(equalTo: textPaddingView.bottomAnchor, constant: -Layout.textBottomPadding)
        ])

        markerPaddingView.translatesAutoresizingMaskIntoConstraints = false
        markerPaddingView.addSubview(markerView)
        NSLayoutConstraint.activate([
            markerView.widthAnchor.constraint(equalToConstant: Layout.markerDiameter),
            markerView.heightAnchor.constraint(equalToConstant: Layout.markerDiameter),
            markerView.leadingAnchor.constraint(equalTo: markerPaddingView.leadingAnchor),
            markerView.trailingAnchor.constraint(equalTo: markerPaddingView.trailingAnchor),
            markerView.topAnchor.constraint(equalTo: markerPaddingView.topAnchor, constant: Layout.markerTopPadding),
            markerView.bottomAnchor.constraint(equalTo: markerPaddingView.bottomAnchor)
        ])

        imageView.imageScaling = .scaleProportionallyDown
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 0)
        imageWidthConstraint?.isActive = true
        imageHeightConstraint?.isActive = true

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(markerPaddingView)
        stackView.addArrangedSubview(textPaddingView)
        stackView.addArrangedSubview(imageView)
        stackView.setCustomSpacing(Layout.markerTrailingGap, after: markerPaddingView)
        stackView.setCustomSpacing(Layout.textIconSpacing, after: textPaddingView)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.trailingPadding),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: Layout.componentTopPadding),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var fittingSize: NSSize {
        var size = stackView.fittingSize
        size.width += Layout.trailingPadding
        size.height += Layout.componentTopPadding
        return size
    }

    override var intrinsicContentSize: NSSize {
        fittingSize
    }

    func configure(title: String, icon: NSImage, marker: MenuBarStatusMarker, font: NSFont) {
        markerView.marker = marker
        markerPaddingView.isHidden = marker == .none

        textField.stringValue = title
        textField.font = font
        textField.textColor = .labelColor
        textPaddingView.isHidden = title.isEmpty

        imageView.image = icon
        imageView.contentTintColor = icon.isTemplate ? .labelColor : nil
        imageWidthConstraint?.constant = icon.size.width
        imageHeightConstraint?.constant = icon.size.height
        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}

private final class MenuBarMarkerView: NSView {
    var marker: MenuBarStatusMarker = .none {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        let isFilled: Bool
        switch marker {
        case .none:
            return
        case .filled(let markerColor):
            color = markerColor.nsColor
            isFilled = true
        case .outline(let markerColor):
            color = markerColor.nsColor
            isFilled = false
        }

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        if isFilled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 1.25
            path.stroke()
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
    var appleScriptSampleRate: Double?
    var trackDuration: Double?
    var playerPosition: Double?
    var currentPlaybackQueueItemID: Int?
    var currentPlaybackQueueSectionID: Int?
    var currentPreloadRecord: AppleMusicPreloadRecord?
    var nextPreloadRecord: AppleMusicPreloadRecord?
    var hasPendingOutputPrediction = false
    var hasMatchingOutputPrediction = false
    var isStatusMarkerTransitioning = false
    var refreshAfter: TimeInterval?
    var unverifiedSampleRate: Double?

    var predictionState: PreloadPredictionState {
        PreloadPredictionState(
            trackIdentity: trackIdentity,
            playbackState: playbackStatus.predictionPlaybackState,
            duration: trackDuration,
            playerPosition: playerPosition,
            currentQueueItemID: currentPlaybackQueueItemID ?? currentPreloadRecord?.queueItemID,
            currentQueueSectionID: currentPlaybackQueueSectionID ?? currentPreloadRecord?.queueSectionID,
            currentRecord: currentPreloadRecord,
            nextRecord: nextPreloadRecord
        )
    }

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

struct PreloadPredictionState: Sendable {
    var trackIdentity: String?
    var playbackState: PreloadPredictionPlaybackState = .unknown
    var duration: Double?
    var playerPosition: Double?
    var currentQueueItemID: Int? = nil
    var currentQueueSectionID: Int? = nil
    var currentRecord: AppleMusicPreloadRecord?
    var nextRecord: AppleMusicPreloadRecord?
}

enum PreloadCacheChange: Sendable {
    case savedFormatOnly(AppleMusicPreloadRecord)
    case enrichedMetadata(AppleMusicPreloadRecord)
    case savedCompleted(AppleMusicPreloadRecord)
    case currentQueueFormatResolved(AppleMusicPreloadRecord)
    case playbackTick(AppleMusicPlaybackItemTick)
    case queueLink(AppleMusicAssetQueueLink)
    case queueSnapshot(AppleMusicQueueSnapshotStoreResult)
    case playbackFormatPromoted
}

private extension PlaybackStatus {
    var predictionPlaybackState: PreloadPredictionPlaybackState {
        switch self {
        case .unknown:
            return .unknown
        case .notRunning:
            return .notRunning
        case .stopped:
            return .stopped
        case .paused:
            return .paused
        case .playing:
            return .playing
        }
    }
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
    private var currentPreloadRecord: AppleMusicPreloadRecord?
    private var currentPlaybackQueueItemID: Int?
    private var currentPlaybackQueueSectionID: Int?
    private var currentPlaybackPosition: Double?
    private var currentPlaybackRemainingTime: Double?
    private var currentPlaybackUpdatedAt: Date?
    private var predictionTransitionGuard: PreloadPredictionTransitionGuard?
    private var loggedStaleTransitionQueueItemIDs: Set<Int> = []
    private var cachedStatus: DetectionStatus?
    private var cachedFormatSource: FormatSource?
    private var cachedUnverifiedSampleRate: Double?
    private var appliedPreloadPrediction: AppliedPreloadPrediction?
    private let initialCacheLookupDelay: TimeInterval = 0.1
    private let cacheLookupWaitLimit: TimeInterval = 3
    private let playbackLosslessPromotionWindow: TimeInterval = 1
    private let playbackLosslessPromotionDeliveryTolerance: TimeInterval = 0.25
    private let appliedPredictionAdoptionWindow: TimeInterval = 10
    private let stalePlaybackTickProtectionWindow: TimeInterval = 8
    private let emptyCacheRetryInterval: TimeInterval = 0.5
    private var firstCacheLookupAt: Date?
    private var cacheLookupDeadline: Date?
    private var nextCacheRefreshAt: Date?
    var preloadCacheDidChange: (([PreloadCacheChange]) -> Void)?

    private enum FormatSource {
        case localFile
        case preloadCache
        case playbackLog
        case fallback
    }

    private struct AppliedPreloadPrediction {
        let record: AppleMusicPreloadRecord
        let previousTrackIdentity: String?
        let previousQueueItemID: Int
        let appliedAt: Date
    }

    private enum PlaybackTickStoreResult {
        case accepted
        case ignoredStale(expectedQueueItemID: Int)
        case confirmedPredicted
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

    func outputSwitchSuppressionFields(for state: AppState, now: Date = Date()) -> String? {
        guard let predictionTransitionGuard else {
            return nil
        }

        let stateQueueItemID = state.currentPlaybackQueueItemID ?? state.currentPreloadRecord?.queueItemID
        guard let stateQueueItemID else {
            return nil
        }

        switch predictionTransitionGuard.evaluate(queueItemID: stateQueueItemID, now: now) {
        case .ignoredStale(let expectedQueueItemID):
            return "reason=transition-guard stateQ=\(stateQueueItemID) expected=\(expectedQueueItemID) stateFormat=\(debugCompactFormat(state.format)) predictedFormat=\(debugCompactFormat(predictionTransitionGuard.predictedFormat))"

        case .expired:
            self.predictionTransitionGuard = nil
            loggedStaleTransitionQueueItemIDs.removeAll()
            return nil

        case .miss:
            self.predictionTransitionGuard = nil
            loggedStaleTransitionQueueItemIDs.removeAll()
            return nil

        case .accepted, .confirmedPredicted:
            return nil
        }
    }

    func rememberAppliedPrediction(
        _ record: AppleMusicPreloadRecord,
        previousTrackIdentity: String?,
        previousQueueItemID: Int
    ) {
        let now = Date()
        appliedPreloadPrediction = AppliedPreloadPrediction(
            record: record,
            previousTrackIdentity: previousTrackIdentity,
            previousQueueItemID: previousQueueItemID,
            appliedAt: now
        )
        predictionTransitionGuard = PreloadPredictionTransitionGuard(
            previousQueueItemID: previousQueueItemID,
            predictedQueueItemID: record.queueItemID,
            predictedFormat: record.format,
            appliedAt: now,
            expiresAt: now.addingTimeInterval(stalePlaybackTickProtectionWindow)
        )
        loggedStaleTransitionQueueItemIDs.removeAll()
    }

    func predictionState() -> PreloadPredictionState {
        guard isAppleMusicRunning else {
            return PreloadPredictionState(playbackState: .notRunning)
        }

        let track = currentTrack()
        if !track.isStopped,
           track.identity == currentTrackIdentity {
            currentTrackAppleScriptSampleRate = track.sampleRate ?? currentTrackAppleScriptSampleRate
        }

        let record = track.identity == currentTrackIdentity ? currentPreloadRecord : nil
        return PreloadPredictionState(
            trackIdentity: track.identity,
            playbackState: track.playbackStatus.predictionPlaybackState,
            duration: track.duration,
            playerPosition: track.playerPosition,
            currentQueueItemID: record?.queueItemID,
            currentQueueSectionID: record?.queueSectionID,
            currentRecord: record,
            nextRecord: record.flatMap { nextPreloadRecord(after: $0) }
        )
    }

    func eventPredictionState() -> PreloadPredictionState {
        eventPredictionState(now: Date())
    }

    func eventPredictionState(now: Date) -> PreloadPredictionState {
        guard isAppleMusicRunning else {
            return PreloadPredictionState(playbackState: .notRunning)
        }

        let record = currentPreloadRecord
            ?? currentPlaybackQueueItemID.flatMap { preloadCache.record(queueItemID: $0) }
        let playbackTiming = estimatedPlaybackTiming(now: now)
        let nextRecord = currentPlaybackQueueItemID.flatMap { queueItemID in
            preloadCache.nextRecord(
                afterQueueItemID: queueItemID,
                queueSectionID: currentPlaybackQueueSectionID
            )
        } ?? record.flatMap { nextPreloadRecord(after: $0) }

        return PreloadPredictionState(
            trackIdentity: currentTrackIdentity,
            playbackState: currentPlaybackQueueItemID == nil ? .unknown : .playing,
            duration: playbackTiming?.duration,
            playerPosition: playbackTiming?.playerPosition,
            currentQueueItemID: currentPlaybackQueueItemID ?? record?.queueItemID,
            currentQueueSectionID: currentPlaybackQueueSectionID ?? record?.queueSectionID,
            currentRecord: record,
            nextRecord: nextRecord
        )
    }

    private func estimatedPlaybackTiming(now: Date) -> (duration: Double, playerPosition: Double)? {
        guard let currentPlaybackPosition,
              let currentPlaybackRemainingTime else {
            return nil
        }

        let duration = currentPlaybackPosition + currentPlaybackRemainingTime
        guard duration.isFinite,
              duration > 0 else {
            return nil
        }

        let elapsed = currentPlaybackUpdatedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return (duration, min(currentPlaybackPosition + elapsed, duration))
    }

    private func nextPreloadRecord(after record: AppleMusicPreloadRecord) -> AppleMusicPreloadRecord? {
        preloadCache.nextRecord(
            afterQueueItemID: record.queueItemID,
            queueSectionID: currentPlaybackQueueItemID == record.queueItemID
                ? currentPlaybackQueueSectionID ?? record.queueSectionID
                : record.queueSectionID
        )
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
            if resolveCurrentQueueFormatIfAvailable(merging: track.format) == nil {
                advanceCacheLookupIfNeeded(for: track, now: now)
            }
        } else if cachedStatus == .unverifiedLossless {
            rememberUnverifiedSampleRate(from: track)
        } else if cachedFormatSource == .playbackLog,
                  preloadCacheRevision != lastResolvedPreloadCacheRevision {
            refinePlaybackLogFormatFromPreloadCache(for: track)
        } else if cachedFormat != nil {
            if cachedFormatSource == .preloadCache,
               cachedFormat?.codec == "ALAC",
               cachedFormat?.bitDepth != nil {
                return makeState(for: track, format: cachedFormat, status: cachedStatus, now: now)
            }
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
        currentPreloadRecord = nil
        currentPlaybackQueueItemID = nil
        currentPlaybackQueueSectionID = nil
        currentPlaybackPosition = nil
        currentPlaybackRemainingTime = nil
        currentPlaybackUpdatedAt = nil
        predictionTransitionGuard = nil
        loggedStaleTransitionQueueItemIDs.removeAll()
        appliedPreloadPrediction = nil
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
            appleScriptSampleRate: track.sampleRate ?? currentTrackAppleScriptSampleRate,
            trackDuration: track.duration,
            playerPosition: track.playerPosition,
            currentPlaybackQueueItemID: currentPlaybackQueueItemID,
            currentPlaybackQueueSectionID: currentPlaybackQueueSectionID,
            currentPreloadRecord: currentPreloadRecord,
            nextPreloadRecord: currentPreloadRecord.flatMap { nextPreloadRecord(after: $0) },
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
        let previousTrackIdentity = currentTrackIdentity
        currentTrackIdentity = track.identity
        currentTrackDetectionStartedAt = now
        currentTrackAppleScriptSampleRate = track.sampleRate
        currentPreloadRecord = nil
        currentPlaybackQueueItemID = nil
        currentPlaybackQueueSectionID = nil
        currentPlaybackPosition = nil
        currentPlaybackRemainingTime = nil
        currentPlaybackUpdatedAt = nil
        predictionTransitionGuard = nil
        loggedStaleTransitionQueueItemIDs.removeAll()
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

        if adoptAppliedPredictionIfEligible(for: track, previousTrackIdentity: previousTrackIdentity, now: now) {
            return
        }

        beginCacheLookup(for: track, now: now)
    }

    private func adoptAppliedPredictionIfEligible(
        for track: TrackSnapshot,
        previousTrackIdentity: String?,
        now: Date
    ) -> Bool {
        guard let prediction = appliedPreloadPrediction else {
            return false
        }

        guard now.timeIntervalSince(prediction.appliedAt) <= appliedPredictionAdoptionWindow else {
            appliedPreloadPrediction = nil
            return false
        }

        if let expectedPreviousIdentity = prediction.previousTrackIdentity,
           expectedPreviousIdentity != previousTrackIdentity {
            appliedPreloadPrediction = nil
            return false
        }

        let observedSampleRate = track.sampleRate ?? currentTrackAppleScriptSampleRate
        guard let predictedSampleRate = prediction.record.format.sampleRate,
              let observedSampleRate,
              abs(predictedSampleRate - observedSampleRate) < 0.5 else {
            debugLog("format: predicted preload adoption skipped reason=sample-rate-mismatch queueItemID=\(prediction.record.queueItemID) predicted=\(Self.debugOptional(prediction.record.format.sampleRate)) observed=\(Self.debugOptional(observedSampleRate))")
            appliedPreloadPrediction = nil
            return false
        }

        let resolvedFormat = track.format?.merging(prediction.record.format) ?? prediction.record.format
        guard resolvedFormat.isReadyForDisplay else {
            appliedPreloadPrediction = nil
            return false
        }

        cachedFormat = resolvedFormat
        cachedStatus = .detected
        cachedFormatSource = .preloadCache
        cachedUnverifiedSampleRate = nil
        currentPreloadRecord = prediction.record
        currentPlaybackQueueItemID = prediction.record.queueItemID
        currentPlaybackQueueSectionID = prediction.record.queueSectionID
        if let duration = track.duration,
           let playerPosition = track.playerPosition {
            currentPlaybackPosition = playerPosition
            currentPlaybackRemainingTime = max(0, duration - playerPosition)
            currentPlaybackUpdatedAt = now
        }
        predictionTransitionGuard = PreloadPredictionTransitionGuard(
            previousQueueItemID: prediction.previousQueueItemID,
            predictedQueueItemID: prediction.record.queueItemID,
            predictedFormat: prediction.record.format,
            appliedAt: prediction.appliedAt,
            expiresAt: now.addingTimeInterval(stalePlaybackTickProtectionWindow)
        )
        loggedStaleTransitionQueueItemIDs.removeAll()
        appliedPreloadPrediction = nil
        clearCacheLookupSchedule()
        debugLog("format.adopt action=predicted q=\(prediction.record.queueItemID) section=\(Self.debugOptional(prediction.record.queueSectionID)) group=\(prediction.record.groupID) format=\(debugCompactFormat(Optional(resolvedFormat))) previous=\(prediction.previousQueueItemID)")
        return true
    }

    private func beginCacheLookup(for track: TrackSnapshot, now: Date) {
        cachedFormat = nil
        cachedStatus = .detecting
        cachedFormatSource = nil
        cachedUnverifiedSampleRate = nil
        currentPreloadRecord = nil
        currentTrackIdentity = track.identity
        currentTrackAppleScriptSampleRate = track.sampleRate ?? currentTrackAppleScriptSampleRate
        firstCacheLookupAt = now.addingTimeInterval(initialCacheLookupDelay)
        cacheLookupDeadline = now.addingTimeInterval(cacheLookupWaitLimit)
        nextCacheRefreshAt = firstCacheLookupAt
        debugLog("cache lookup scheduled: initialDelay=\(initialCacheLookupDelay)s deadline=\(debugTime(cacheLookupDeadline)) target title=\(Self.debugQuote(track.title)) durationInt=\(Self.debugDurationInt(track.duration))")

        if case .found = preloadCache.lookup(title: track.title, duration: track.duration) {
            resolveFormatFromPreloadCache(for: track, now: now)
        }
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
        debugLog("cache lookup: target title=\(Self.debugQuote(track.title)) durationInt=\(Self.debugDurationInt(track.duration)) kind=\(Self.debugQuote(track.kind)) cached=\(preloadCache.count) cacheIDs=\(debugPreloadCacheIDs()) metadataIDs=\(debugPreloadMetadataIDs())")

        switch preloadCache.lookup(title: track.title, duration: track.duration) {
        case .found(let record):
            let resolvedFormat = track.format?.merging(record.format) ?? record.format
            if resolvedFormat.isReadyForDisplay {
                cachedFormat = resolvedFormat
                cachedStatus = .detected
                cachedFormatSource = .preloadCache
                cachedUnverifiedSampleRate = nil
                currentPreloadRecord = record
                clearCacheLookupSchedule()
                debugLog("format.resolve action=metadata-match q=\(record.queueItemID) group=\(record.groupID) format=\(debugCompactFormat(Optional(resolvedFormat)))")
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
        currentPreloadRecord = nil
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
                currentPreloadRecord = nil
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
        currentPreloadRecord = nil
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
        var changes: [PreloadCacheChange] = []

        for entry in entries {
            if let snapshot = parser.parseQueueSnapshot(entry.message) {
                if let change = rememberQueueSnapshot(snapshot) {
                    changes.append(change)
                }
            } else if let link = parser.parseAssetQueueLink(entry.message),
               rememberQueueLink(link) {
                changes.append(.queueLink(link))
            }

            if let tick = parser.parsePlaybackItemTick(entry.message) {
                switch rememberPlaybackTick(tick) {
                case .accepted, .confirmedPredicted:
                    changes.append(.playbackTick(tick))
                    if let record = resolveCurrentQueueFormatIfAvailable() {
                        changes.append(.currentQueueFormatResolved(record))
                    }

                case .ignoredStale:
                    break
                }
            }

            if parser.parsePlaybackFormat(entry.message)?.codec == "ALAC" {
                if promotePlaybackLosslessIfEligible(from: entry) {
                    changes.append(.playbackFormatPromoted)
                }
            }

            let completedRecords = preloadAssembler.ingest(
                message: entry.message,
                date: entry.date,
                parser: parser
            )

            for record in completedRecords {
                if let change = rememberCompletedPreloadRecord(record) {
                    changes.append(change)
                }
                if record.queueItemID == currentPlaybackQueueItemID,
                   let resolvedRecord = resolveCurrentQueueFormatIfAvailable() {
                    changes.append(.currentQueueFormatResolved(resolvedRecord))
                }
            }
        }

        if !changes.isEmpty {
            preloadCacheDidChange?(changes)
        }
    }

    private func rememberQueueSnapshot(_ snapshot: AppleMusicQueueSnapshot) -> PreloadCacheChange? {
        let result = preloadCache.rememberQueueSnapshot(snapshot)
        guard !result.changedLinks.isEmpty else {
            return nil
        }

        debugLog("preload.snapshot source=\(snapshot.source.logDescription) section=\(debugQueueSnapshotSection(snapshot)) items=\(debugQueueSnapshotItems(snapshot))")
        for reorder in result.reorders {
            debugLog("preload.reorder source=\(reorder.source.logDescription) section=\(reorder.queueSectionID) current=\(reorder.currentQueueItemID) oldNext=\(reorder.oldNextQueueItemID) newNext=\(reorder.newNextQueueItemID)")
        }

        return .queueSnapshot(result)
    }

    @discardableResult
    private func rememberQueueLink(_ link: AppleMusicAssetQueueLink) -> Bool {
        guard preloadCache.rememberNext(link) else {
            return false
        }

        debugLog("preload.link section=\(link.queueSectionID) prior=\(link.priorQueueItemID) next=\(link.nextQueueItemID)")
        return true
    }

    private func rememberPlaybackTick(_ tick: AppleMusicPlaybackItemTick) -> PlaybackTickStoreResult {
        let now = Date()

        if let predictionTransitionGuard {
            switch predictionTransitionGuard.evaluate(queueItemID: tick.queueItemID, now: now) {
            case .ignoredStale(let expectedQueueItemID):
                if loggedStaleTransitionQueueItemIDs.insert(tick.queueItemID).inserted {
                    debugLog(
                        "playback.tick action=ignored reason=stale-after-prediction q=\(tick.queueItemID) expected=\(expectedQueueItemID) section=\(tick.queueSectionID) position=\(debugSeconds(tick.position)) remaining=\(debugSeconds(tick.remainingTime))"
                    )
                }
                return .ignoredStale(expectedQueueItemID: expectedQueueItemID)

            case .confirmedPredicted:
                acceptPlaybackTick(tick, now: now, action: "confirmed", extra: nil)
                return .confirmedPredicted

            case .miss:
                let previous = predictionTransitionGuard.previousQueueItemID
                let predicted = predictionTransitionGuard.predictedQueueItemID
                self.predictionTransitionGuard = nil
                loggedStaleTransitionQueueItemIDs.removeAll()
                acceptPlaybackTick(
                    tick,
                    now: now,
                    action: "accepted",
                    extra: " reason=transition-miss previous=\(previous) predicted=\(predicted)"
                )
                return .accepted

            case .expired:
                self.predictionTransitionGuard = nil
                loggedStaleTransitionQueueItemIDs.removeAll()
                acceptPlaybackTick(tick, now: now, action: "accepted", extra: " reason=guard-expired")
                return .accepted

            case .accepted:
                break
            }
        }

        acceptPlaybackTick(tick, now: now, action: "accepted", extra: nil)
        return .accepted
    }

    private func acceptPlaybackTick(
        _ tick: AppleMusicPlaybackItemTick,
        now: Date,
        action: String,
        extra: String?
    ) {
        currentPlaybackQueueItemID = tick.queueItemID
        currentPlaybackQueueSectionID = tick.queueSectionID
        currentPlaybackPosition = tick.position
        currentPlaybackRemainingTime = tick.remainingTime
        currentPlaybackUpdatedAt = now
        debugLog(
            "playback.tick action=\(action) q=\(tick.queueItemID) section=\(tick.queueSectionID) position=\(debugSeconds(tick.position)) remaining=\(debugSeconds(tick.remainingTime)) \(debugPredictionStatus(for: tick))\(extra ?? "")"
        )
    }

    private func debugPredictionStatus(for tick: AppleMusicPlaybackItemTick) -> String {
        let currentRecord = currentPreloadRecord?.queueItemID == tick.queueItemID
            ? currentPreloadRecord
            : preloadCache.record(queueItemID: tick.queueItemID)

        guard let nextRecord = preloadCache.nextRecord(
            afterQueueItemID: tick.queueItemID,
            queueSectionID: tick.queueSectionID
        ) else {
            return "prediction=waiting-next"
        }

        if let currentRecord,
           currentRecord.format.sampleRate == nextRecord.format.sampleRate,
           currentRecord.format.bitDepth == nextRecord.format.bitDepth {
            return "prediction=matching-format next=\(nextRecord.queueItemID)"
        }

        let applyIn = tick.remainingTime <= 3.5 ? 0 : max(tick.remainingTime - 3.0, 0)
        let currentFormatStatus = currentRecord == nil ? " current-format=unknown" : ""
        return "prediction=armed next=\(nextRecord.queueItemID) format=\(debugCompactFormat(nextRecord.format)) applyIn=\(debugSeconds(applyIn))\(currentFormatStatus)"
    }

    private func debugQueueSnapshotItems(_ snapshot: AppleMusicQueueSnapshot) -> String {
        let items = snapshot.items
            .map { String($0.queueItemID) }
            .joined(separator: ",")
        return "[\(items)]"
    }

    private func debugQueueSnapshotSection(_ snapshot: AppleMusicQueueSnapshot) -> String {
        let sectionIDs = Set(snapshot.items.map(\.queueSectionID))
        guard sectionIDs.count == 1,
              let sectionID = sectionIDs.first else {
            return "mixed"
        }

        return String(sectionID)
    }

    private func resolveCurrentQueueFormatIfAvailable(merging trackFormat: AudioFormat? = nil) -> AppleMusicPreloadRecord? {
        guard let queueItemID = currentPlaybackQueueItemID,
              let record = preloadCache.record(queueItemID: queueItemID) else {
            return nil
        }

        let resolvedFormat = trackFormat?.merging(record.format)
            ?? cachedFormat?.merging(record.format)
            ?? record.format
        guard resolvedFormat.isReadyForDisplay else {
            return nil
        }

        guard currentPreloadRecord?.queueItemID != record.queueItemID
            || cachedFormat != resolvedFormat
            || cachedFormatSource != .preloadCache else {
            return nil
        }

        cachedFormat = resolvedFormat
        cachedStatus = .detected
        cachedFormatSource = .preloadCache
        cachedUnverifiedSampleRate = nil
        currentPreloadRecord = record
        clearCacheLookupSchedule()
        debugLog("format.resolve action=current q=\(record.queueItemID) group=\(record.groupID) format=\(debugCompactFormat(Optional(resolvedFormat)))")
        return record
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
        currentPreloadRecord = nil
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
        currentPreloadRecord = record
        debugLog("format: playback lossless refined from preload cache queueItemID=\(record.queueItemID) group=\(record.groupID) \(debugFormat(resolvedFormat))")
    }

    @discardableResult
    private func rememberCompletedPreloadRecord(_ record: AppleMusicPreloadRecord) -> PreloadCacheChange? {
        let result = preloadCache.store(record)
        let previousRecord: AppleMusicPreloadRecord?
        let storedRecord: AppleMusicPreloadRecord

        switch result {
        case .inserted(let current):
            previousRecord = nil
            storedRecord = current

        case .updated(let previous, let current):
            previousRecord = previous
            storedRecord = current

        case .unchanged:
            return nil
        }

        preloadCacheRevision += 1
        if previousRecord?.hasMetadata == false && storedRecord.hasMetadata {
            debugLog("preload.metadata action=enriched q=\(storedRecord.queueItemID) title=\(Self.debugQuote(storedRecord.title)) durationInt=\(Self.debugDurationInt(storedRecord.duration))")
            return .enrichedMetadata(storedRecord)
        } else if storedRecord.hasMetadata {
            if let previousRecord {
                debugLog("preload.format action=updated-completed q=\(storedRecord.queueItemID) section=\(Self.debugOptional(storedRecord.queueSectionID)) title=\(Self.debugQuote(storedRecord.title)) oldGroup=\(previousRecord.groupID) oldFormat=\(debugCompactFormat(Optional(previousRecord.format))) newGroup=\(storedRecord.groupID) newFormat=\(debugCompactFormat(Optional(storedRecord.format)))")
            } else {
                debugLog("preload.format action=saved-completed q=\(storedRecord.queueItemID) section=\(Self.debugOptional(storedRecord.queueSectionID)) title=\(Self.debugQuote(storedRecord.title)) group=\(storedRecord.groupID) format=\(debugCompactFormat(Optional(storedRecord.format)))")
            }
            return .savedCompleted(storedRecord)
        } else {
            if let previousRecord {
                debugLog("preload.format action=updated q=\(storedRecord.queueItemID) section=\(Self.debugOptional(storedRecord.queueSectionID)) oldGroup=\(previousRecord.groupID) oldFormat=\(debugCompactFormat(Optional(previousRecord.format))) newGroup=\(storedRecord.groupID) newFormat=\(debugCompactFormat(Optional(storedRecord.format)))")
            } else {
                debugLog("preload.format action=saved q=\(storedRecord.queueItemID) section=\(Self.debugOptional(storedRecord.queueSectionID)) group=\(storedRecord.groupID) format=\(debugCompactFormat(Optional(storedRecord.format)))")
            }
            return .savedFormatOnly(storedRecord)
        }
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
            candidates.filter { candidate in
                candidate.title.map { titlesMatch($0, targetTitle) } ?? false
            }
        } ?? []
        let durationMatches = duration.map { targetDuration in
            candidates.filter { candidate in
                candidate.duration.map { durationsMatch($0, targetDuration) } ?? false
            }
        } ?? []
        let titleOnlyMatches = titleMatches.filter { candidate in
            guard let candidateDuration = candidate.duration else {
                return true
            }
            return duration.map { !durationsMatch(candidateDuration, $0) } ?? true
        }
        let durationOnlyMatches = durationMatches.filter { candidate in
            guard let candidateTitle = candidate.title else {
                return true
            }
            return title.map { !titlesMatch(candidateTitle, $0) } ?? true
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
            .map { "id=\($0.queueItemID) title=\(Self.debugQuote($0.title)) durationInt=\(Self.debugDurationInt($0.duration)) group=\($0.groupID) rawDuration=\(Self.debugOptional($0.duration))" }
            .joined(separator: " | ")
    }

    private func debugPreloadCacheIDs() -> String {
        let ids = preloadCache.records
            .map(\.queueItemID)
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        return "[\(ids)]"
    }

    private func debugPreloadMetadataIDs() -> String {
        let ids = preloadCache.records
            .filter(\.hasMetadata)
            .map(\.queueItemID)
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        return "[\(ids)]"
    }

    private func debugFormat(_ format: AudioFormat?) -> String {
        guard let format else {
            return "-"
        }

        return "codec=\(Self.debugOptional(format.codec)) bitDepth=\(Self.debugOptional(format.bitDepth)) bitRate=\(Self.debugOptional(format.bitRate)) sampleRate=\(Self.debugOptional(format.sampleRate))"
    }

    private func debugCompactFormat(_ format: AudioFormat) -> String {
        let sampleRate = format.sampleRate.map { String(Int($0.rounded())) } ?? "unknown"
        let bitDepth = format.bitDepth.map(String.init) ?? "-"
        return "\(sampleRate)/\(bitDepth)"
    }

    private func debugCompactFormat(_ format: AudioFormat?) -> String {
        guard let format else {
            return "unknown/-"
        }

        let codec = format.codec ?? "unknown"
        return "\(codec)/\(debugCompactFormat(format))"
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

    private func debugSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
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
    process == "Music" AND (subsystem == "com.apple.amp.mediaplaybackcore" OR eventMessage CONTAINS[c] "item-begin" OR eventMessage CONTAINS[c] "ITEM TICK" OR eventMessage CONTAINS[c] "ASSET QUEUE" OR eventMessage CONTAINS[c] "Queue->Player synchronization completed" OR eventMessage CONTAINS[c] "playerItems:" OR eventMessage CONTAINS[c] "loadedQueueItems:" OR eventMessage CONTAINS[c] "QUEUE EVENT PROCESSED" OR eventMessage CONTAINS[c] "synchronizeQueueItemsToPlayer" OR eventMessage CONTAINS[c] "prior item" OR eventMessage CONTAINS[c] "audio-format-changed" OR eventMessage CONTAINS[c] "PlaybackEventStream" OR eventMessage CONTAINS[c] "Engagement" OR eventMessage CONTAINS[c] "PBAudioFormat" OR eventMessage CONTAINS[c] "Audio format changed")
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
