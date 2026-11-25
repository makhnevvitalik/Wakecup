import AppKit
import Combine
import SwiftUI

final class WakecupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { styleMask.contains(.titled) }

    // AppKit matches standard Edit shortcuts for the current keyboard layout.
    // This panel has no main menu, so its active native editor is the target.
    private lazy var editingMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (key, action) in [("a", #selector(NSText.selectAll(_:))), ("c", #selector(NSText.copy(_:))),
                              ("v", #selector(NSText.paste(_:))), ("x", #selector(NSText.cut(_:)))] {
            menu.addItem(NSMenuItem(title: "", action: action, keyEquivalent: key))
        }
        menu.addItem(NSMenuItem(title: "", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "", action: #selector(UndoManager.redo), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; menu.addItem(redo)
        return menu
    }()

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField, field.currentEditor() === editor,
           !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
            makeFirstResponder(nil)
        }
        let previous = firstResponder
        super.sendEvent(event)
        AppStyle.clearUnchangedFocus(in: self, after: event, previous: previous)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor = firstResponder as? NSTextView, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        for item in editingMenu.items {
            switch item.action {
            case #selector(UndoManager.undo): item.target = editor.undoManager; item.isEnabled = editor.undoManager?.canUndo == true
            case #selector(UndoManager.redo): item.target = editor.undoManager; item.isEnabled = editor.undoManager?.canRedo == true
            default: item.target = editor; item.isEnabled = true
            }
        }
        return editingMenu.performKeyEquivalent(with: event) || super.performKeyEquivalent(with: event)
    }
}

private final class MenuHostingController<Content: View>: NSHostingController<Content> {
    var contentDidLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        contentDidLayout?()
    }
}

final class MenuPanelController: NSObject, NSWindowDelegate {
    private let panel = WakecupPanel(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 500),
        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    private let container = NSViewController()
    private var settingsWindow: WakecupPanel?
    private var standaloneShortcutEditor: DisplayShortcutEditor?
    private let model: SessionModel
    private let hosting: MenuHostingController<WakecupOptionsView>
    private let header: MenuHostingController<WakecupHeaderView>
    private let actionFeedback = FeedbackRegion(.primaryAction)
    private let footerFeedback = FeedbackRegion(.footer)
    private var feedbackRegions: [FeedbackRegion] { [actionFeedback, footerFeedback] }
    private var headerHeight: NSLayoutConstraint!
    private var feedbackTimer: Timer?
    private let reduceMotion: () -> Bool
    private var layoutUpdateScheduled = false
    private var modelObservation: AnyCancellable?
    private let scrollView = NSScrollView()
    private let footer: NSHostingController<SessionSettingsFooter>
    private let footerHeight = MenuLayout.helpLinkHeight + AppStyle.Layout.panelInset
    private var languageObservation: AnyCancellable?
    private let statusButton: () -> NSStatusBarButton?
    private var naturalSize = NSSize(width: MenuLayout.width, height: 500)
    private var placementScreen: NSScreen?
    private var positionedPanelFrame: NSRect?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    @MainActor init(model: SessionModel, updates: UpdateChecker,
         statusButton: @escaping () -> NSStatusBarButton?, showHelp: @escaping () -> Void = {},
         showAbout: @escaping () -> Void = {}, showMCPSetup: @escaping () -> Void = {},
         configureDisplayShortcut: @escaping (Bool, @escaping (Bool) -> Void) -> Void = { _, complete in complete(false) }, helperInteraction: HelperInteraction = .init(),
         isMCPEnabled: @escaping () -> Bool = { false }, setMCPEnabled: @escaping (Bool) -> Void = { _ in },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.model = model
        self.statusButton = statusButton
        self.reduceMotion = reduceMotion
        header = MenuHostingController(rootView: WakecupHeaderView(model: model, updates: updates, showAbout: showAbout,
            showMCPSetup: showMCPSetup, helperInteraction: helperInteraction,
            isMCPEnabled: isMCPEnabled, setMCPEnabled: setMCPEnabled))
        hosting = MenuHostingController(rootView: WakecupOptionsView(model: model,
            configureDisplayShortcut: configureDisplayShortcut, helperInteraction: helperInteraction))
        header.sizingOptions = [.preferredContentSize]
        hosting.sizingOptions = [.preferredContentSize]
        footer = NSHostingController(rootView: SessionSettingsFooter(showHelp: showHelp))
        super.init()
        footer.sizingOptions = []
        panel.title = "Wakecup"
        panel.delegate = self
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.allowsToolTipsWhenApplicationIsInactive = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = MenuLayout.panelCornerRadius
        background.layer?.masksToBounds = true
        container.view = background
        container.addChild(header)
        for region in feedbackRegions { region.attach(to: container) }
        container.addChild(hosting)
        container.addChild(footer)
        panel.contentViewController = container

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = hosting.view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)
        let headerView = header.view
        let footerView = footer.view
        for area in [headerView, footerView] {
            area.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(area)
        }
        let actionFeedbackArea = actionFeedback.view
        let footerFeedbackArea = footerFeedback.view
        headerHeight = headerView.heightAnchor.constraint(equalToConstant: ceil(headerView.fittingSize.height))
        NSLayoutConstraint.activate([
            headerHeight, actionFeedback.height, footerFeedback.height,
            headerView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: background.topAnchor),
            actionFeedbackArea.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            actionFeedbackArea.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            actionFeedbackArea.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            footerFeedbackArea.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footerFeedbackArea.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footerFeedbackArea.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            footerView.heightAnchor.constraint(equalToConstant: footerHeight),
            footerView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: actionFeedbackArea.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerFeedbackArea.topAnchor)
        ])
        hosting.view.autoresizingMask = []
        hosting.view.setFrameSize(naturalSize)
        hosting.contentDidLayout = { [weak self] in self?.scheduleLayoutUpdate() }
        header.contentDidLayout = { [weak self] in self?.scheduleLayoutUpdate() }
        modelObservation = model.objectWillChange.sink { [weak self] in self?.scheduleLayoutUpdate() }
        languageObservation = AppLocalization.shared.$language.sink { [weak self] _ in
            self?.settingsWindow?.title = localized("Wakecup Settings")
            self?.scheduleLayoutUpdate()
        }
        updateFeedback(animate: false)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        feedbackTimer?.invalidate()
        removeMonitors()
        NotificationCenter.default.removeObserver(self)
    }

    @MainActor func show(restoringScrollOffset: CGFloat? = nil) {
        if raiseShortcutEditor() { return }
        if settingsWindow?.attachedSheet != nil {
            showWindow()
            return
        }
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeFirstResponder(nil)
            settingsWindow.orderOut(nil)
        }
        moveContent(to: panel)
        let wasVisible = panel.isVisible
        let scrollOffset = restoringScrollOffset ?? (wasVisible ? scrollDistanceFromTop : 0)
        updateContentSize()
        updateFeedback(animate: false)
        let button = statusButton()
        let iconFrame = button.flatMap { button in button.window?.convertToScreen(button.convert(button.bounds, to: nil)) }
        placementScreen = button?.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen = placementScreen else { return }
        let frame = detachedPanelFrame(contentSize: panelContentSize, screenFrame: screen.frame,
            visibleFrame: panelVisibleFrame(on: screen), statusItemFrame: iconFrame,
            previousFrame: wasVisible ? positionedPanelFrame : nil)
        positionedPanelFrame = frame
        panel.setFrame(frame, display: true)
        updateDocumentSize(scrollOffset: scrollOffset)
        installMonitors()
        AppStyle.showWithoutInitialControlFocus(panel)
    }

    @MainActor func reopen() {
        if !raiseShortcutEditor() { showWindow() }
    }

    @MainActor private func raiseShortcutEditor() -> Bool {
        guard let editor = standaloneShortcutEditor else { return false }
        editor.showWindow()
        return true
    }

    func showWindow() {
        if let window = settingsWindow, let sheet = window.attachedSheet {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFront(nil)
            sheet.makeKeyAndOrderFront(nil)
            return
        }
        let firstPresentation = settingsWindow == nil
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.title = localized("Wakecup Settings")
        let scrollOffset = window.isVisible || panel.isVisible ? scrollDistanceFromTop : 0
        hidePanel()
        moveContent(to: window)
        updateContentSize()
        updateFeedback(animate: false)
        resizeSettingsWindow(window, center: firstPresentation, scrollOffset: scrollOffset)
        NSApp.activate(ignoringOtherApps: true)
        AppStyle.showWithoutInitialControlFocus(window)
    }

    private func makeSettingsWindow() -> WakecupPanel {
        let window = WakecupPanel(contentRect: NSRect(origin: .zero, size: panelContentSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.delegate = self
        return window
    }

    private func moveContent(to window: NSWindow) {
        guard window.contentViewController !== container else { return }
        panel.contentViewController = nil
        settingsWindow?.contentViewController = nil
        (container.view as? NSVisualEffectView)?.layer?.cornerRadius =
            window === panel ? MenuLayout.panelCornerRadius : 0
        window.contentViewController = container
    }

    func close() {
        guard settingsWindow?.isVisible != true else { return }
        hidePanel()
        discardSettingsDraft()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        updateFeedback(animate: false)
        removeMonitors()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel,
              panel.isVisible, panel.frame != positionedPanelFrame else { return }
        // AppKit can reposition the panel while one of its popovers is open.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.frame != self.positionedPanelFrame else { return }
            self.resizeVisiblePanel(scrollOffset: self.scrollDistanceFromTop)
        }
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow?.makeFirstResponder(nil)
        updateFeedback(animate: false)
        discardSettingsDraft()
    }

    private func discardSettingsDraft() {
        if model.hasSettingsDraft || model.endTimeInputInvalid { model.discardSettingsDraft() }
    }

    @MainActor func leaveForAuxiliaryWindow(restoreFocusMatching identifier: String? = nil) -> (() -> Void)? {
        guard let source = panel.isVisible ? panel : settingsWindow.flatMap({ $0.isVisible ? $0 : nil }) else { return nil }
        let isPanel = source === panel
        let scrollOffset = scrollDistanceFromTop
        let responder = AppStyle.restorableControl(in: source)
        let trigger = identifier == nil || responder?.identifier?.rawValue == identifier ? responder : nil
        hidePanel()
        return { [weak self, weak source, weak trigger] in
            guard let self, let source else { return }
            if isPanel {
                guard self.settingsWindow?.isVisible != true, self.model.showInMenuBar else { return }
                self.show(restoringScrollOffset: scrollOffset)
            } else if source.isVisible, source.attachedSheet == nil {
                source.makeKeyAndOrderFront(nil)
            }
            if let trigger, trigger.window === source, source.isVisible, trigger.isEnabled {
                source.makeFirstResponder(trigger)
            }
        }
    }

    @MainActor func configureDisplayShortcut(requiresShortcut: Bool, completion: @escaping (Bool) -> Void) {
        if raiseShortcutEditor() {
            completion(false)
            return
        }
        let owner = settingsWindow.flatMap { $0.isVisible ? $0 : nil }
        guard model.canChangeDisplayShortcut, owner?.attachedSheet == nil else { completion(false); return }
        let triggerID = requiresShortcut ? "WakecupDisplayMode" : "WakecupConfigureDisplayShortcut"
        let returnToSource = leaveForAuxiliaryWindow(restoreFocusMatching: triggerID)
        let editor = DisplayShortcutEditor.present(model: model, owner: owner, requiresShortcut: requiresShortcut) { [weak self] saved in
            self?.standaloneShortcutEditor = nil
            completion(saved)
            returnToSource?()
        }
        if owner == nil { standaloneShortcutEditor = editor }
    }

    func settingsSheetOwner() -> NSWindow? {
        showWindow()
        guard settingsWindow?.attachedSheet == nil else { return nil }
        return settingsWindow
    }

    private func scheduleLayoutUpdate() {
        guard !layoutUpdateScheduled else { return }
        layoutUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutUpdateScheduled = false
            self.updateContentSize()
            self.updateFeedback()
        }
    }

    private func updateContentSize() {
        let size = hosting.view.fittingSize
        let topHeight = ceil(header.view.fittingSize.height)
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
              topHeight > 0, topHeight.isFinite else { return }
        let next = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard next != naturalSize || topHeight != headerHeight.constant else { return }
        let offset = scrollDistanceFromTop
        naturalSize = next
        headerHeight.constant = topHeight
        resizeVisibleSurface(scrollOffset: offset)
    }

    private func updateFeedback(animate: Bool = true) {
        let animated = animate && !reduceMotion() && (panel.isVisible || settingsWindow?.isVisible == true)
        if animated && feedbackTimer != nil { return }
        let regions = feedbackRegions
        let messages = regions.map { SessionFeedback.current(for: model, placement: $0.placement) }
        guard feedbackTimer != nil || zip(regions, messages).contains(where: { $0.current != $1 }) else { return }

        feedbackTimer?.invalidate()
        feedbackTimer = nil
        let transitions = zip(regions, messages).map { $0.transition(to: $1, animated: animated) }
        let offset = scrollDistanceFromTop
        if !animated {
            transitions.forEach { $0(1) }
            resizeVisibleSurface(scrollOffset: offset)
            return
        }

        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.reduceMotion() {
                self.updateFeedback(animate: false)
                return
            }
            let fraction = min((ProcessInfo.processInfo.systemUptime - start) / AppStyle.FeedbackTransition.duration, 1)
            let progress = AppStyle.FeedbackTransition.progress(fraction)
            let scrollOffset = self.scrollDistanceFromTop
            transitions.forEach { $0(progress) }
            self.resizeVisibleSurface(scrollOffset: scrollOffset)
            if fraction == 1 {
                timer.invalidate()
                self.feedbackTimer = nil
                self.updateFeedback()
            }
        }
        feedbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var panelContentSize: NSSize {
        NSSize(width: naturalSize.width, height: headerHeight.constant + naturalSize.height + footerHeight
               + actionFeedback.height.constant + footerFeedback.height.constant)
    }

    @objc private func screenParametersDidChange() {
        resizeVisibleSurface(scrollOffset: scrollDistanceFromTop)
    }

    private func resizeVisibleSurface(scrollOffset: CGFloat) {
        if panel.isVisible {
            resizeVisiblePanel(scrollOffset: scrollOffset)
        } else if let window = settingsWindow, window.isVisible {
            resizeSettingsWindow(window, center: false, scrollOffset: scrollOffset)
        }
    }

    private func resizeSettingsWindow(_ window: NSWindow, center: Bool, scrollOffset: CGFloat) {
        let screen = window.screen ?? NSScreen.main
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: panelContentSize)).size
        let limit = screen.map { screen in
            center ? screen.visibleFrame.height - 16 : window.frame.maxY - screen.visibleFrame.minY
        } ?? frameSize.height
        let height = min(frameSize.height, max(1, limit))
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: frameSize.width, height: height)
        window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
        if center { window.center() }
        updateDocumentSize(scrollOffset: scrollOffset)
        window.displayIfNeeded()
    }

    private func resizeVisiblePanel(scrollOffset: CGFloat) {
        guard panel.isVisible, let screen = panel.screen ?? placementScreen ?? NSScreen.main else { return }
        let frame = detachedPanelFrame(contentSize: panelContentSize, screenFrame: screen.frame,
            visibleFrame: panelVisibleFrame(on: screen), statusItemFrame: nil, previousFrame: positionedPanelFrame)
        positionedPanelFrame = frame
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        updateDocumentSize(scrollOffset: scrollOffset)
        panel.displayIfNeeded()
    }

    private func panelVisibleFrame(on screen: NSScreen) -> NSRect {
        var visible = screen.visibleFrame
        // The menu bar may be temporarily hidden while its popovers are in use.
        let topInset = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        let top = min(visible.maxY, screen.frame.maxY - topInset)
        visible.size.height = max(0, top - visible.minY)
        return visible
    }

    private var scrollDistanceFromTop: CGFloat {
        let visible = scrollView.documentVisibleRect
        let document = hosting.view.bounds
        return max(0, hosting.view.isFlipped ? visible.minY - document.minY : document.maxY - visible.maxY)
    }

    private func updateDocumentSize(scrollOffset: CGFloat) {
        hosting.view.setFrameSize(naturalSize)
        if let window = container.view.window {
            scrollView.hasVerticalScroller = panelContentSize.height > window.contentLayoutRect.height + 0.5
        }
        container.view.layoutSubtreeIfNeeded()
        let available = max(0, naturalSize.height - scrollView.contentSize.height)
        let distance = min(scrollOffset, available)
        let origin = hosting.view.isFlipped ? distance : available - distance
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, NSApp.modalWindow == nil else { return }
            let point = NSEvent.mouseLocation
            if self.panel.frame.contains(point) { return }
            if let button = self.statusButton(), let window = button.window,
               window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
            self.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, NSApp.modalWindow == nil else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, event.window === self.panel { self.close(); return nil }
                return event
            }
            if event.window === self.panel || event.window === self.statusButton()?.window { return event }
            // Native settings and picker menus use their own popup windows.
            if let window = event.window, window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return event }
            self.close()
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }
}

// Each area keeps its hosting views in place while both heights animate together.
private final class FeedbackRegion {
    let placement: SessionFeedback.Placement
    let view = NSView()
    lazy var height = view.heightAnchor.constraint(equalToConstant: 0)

    private let incoming = NSHostingController(rootView: SessionFeedbackView(feedback: nil))
    private let outgoing = NSHostingController(rootView: SessionFeedbackView(feedback: nil, outgoing: true))

    var current: SessionFeedback? { incoming.rootView.feedback }

    init(_ placement: SessionFeedback.Placement) { self.placement = placement }

    func attach(to container: NSViewController) {
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(view)
        for host in [outgoing, incoming] {
            container.addChild(host)
            host.sizingOptions = []
            host.view.autoresizingMask = [.minYMargin]
            view.addSubview(host.view)
        }
    }

    func transition(to next: SessionFeedback?, animated: Bool) -> (CGFloat) -> Void {
        let targetHeight = next?.height ?? 0
        if animated && next == current { return { _ in } }
        let startHeight = height.constant
        setFeedback(animated ? current : nil, in: outgoing)
        setFeedback(next, in: incoming)
        incoming.view.alphaValue = animated ? 0 : 1
        outgoing.view.alphaValue = animated ? 1 : 0
        return { [self] progress in
            incoming.view.alphaValue = progress
            outgoing.view.alphaValue = 1 - progress
            height.constant = (startHeight + (targetHeight - startHeight) * progress).rounded()
            if progress == 1 { setFeedback(nil, in: outgoing) }
        }
    }

    private func setFeedback(_ feedback: SessionFeedback?, in host: NSHostingController<SessionFeedbackView>) {
        host.rootView = SessionFeedbackView(feedback: feedback, outgoing: host === outgoing)
        let height = feedback?.height ?? 0
        host.view.frame = NSRect(x: 0, y: view.bounds.height - height, width: MenuLayout.width, height: height)
    }
}
