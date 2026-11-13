import AppKit
import Combine
import SwiftUI

final class WakecupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
        super.sendEvent(event)
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

private final class MenuHostingController: NSHostingController<WakecupView> {
    var contentDidLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        contentDidLayout?()
    }
}

final class MenuPanelController {
    private let panel = WakecupPanel(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 500),
        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    private let model: SessionModel
    private let hosting: MenuHostingController
    private let scrollView = NSScrollView()
    private let footer: NSHostingController<SessionSettingsFooter>
    private var footerHeight: NSLayoutConstraint!
    private var settingsObservation: AnyCancellable?
    private let statusButton: () -> NSStatusBarButton?
    private var naturalSize = NSSize(width: MenuLayout.width, height: 500)
    private var placementScreen: NSScreen?
    private var screenObservation: NSObjectProtocol?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var presentingShortcutEditor = false

    var isVisible: Bool { panel.isVisible }

    init(model: SessionModel, statusButton: @escaping () -> NSStatusBarButton?, showHelp: @escaping () -> Void = {},
         showAbout: @escaping () -> Void = {}, showMCPSetup: @escaping () -> Void = {},
         configureDisplayShortcut: @escaping (Bool) -> Bool, helperInteraction: HelperInteraction = .init(),
         isMCPEnabled: @escaping () -> Bool = { false }, setMCPEnabled: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        self.statusButton = statusButton
        hosting = MenuHostingController(rootView: WakecupView(model: model, showAbout: showAbout,
            configureDisplayShortcut: configureDisplayShortcut, showMCPSetup: showMCPSetup,
            helperInteraction: helperInteraction, isMCPEnabled: isMCPEnabled, setMCPEnabled: setMCPEnabled))
        hosting.sizingOptions = [.preferredContentSize]
        footer = NSHostingController(rootView: SessionSettingsFooter(model: model, showHelp: showHelp))
        footer.sizingOptions = []
        panel.title = "Wakecup"
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
        let container = NSViewController()
        container.view = background
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
        let footerView = footer.view
        footerView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footerView)
        footerHeight = footerView.heightAnchor.constraint(equalToConstant: footer.rootView.preferredHeight)
        NSLayoutConstraint.activate([
            footerHeight,
            footerView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor)
        ])
        hosting.view.autoresizingMask = []
        hosting.view.setFrameSize(naturalSize)
        hosting.contentDidLayout = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateSize(self.hosting.view.fittingSize)
            }
        }
        settingsObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateFooter() }
        }
        screenObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.resizeVisiblePanel() }
    }

    deinit {
        removeMonitors()
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
    }

    func show() {
        // The panel is above ordinary modal windows. Do not let status clicks or
        // session updates reopen it over an explanation/confirmation dialog.
        guard !presentingShortcutEditor, NSApp.modalWindow == nil else { return }
        let wasVisible = panel.isVisible
        let scrollOffset = wasVisible ? scrollDistanceFromTop : 0
        hosting.view.layoutSubtreeIfNeeded()
        updateSize(hosting.view.fittingSize)
        let button = statusButton()
        let iconFrame = button.flatMap { button in button.window?.convertToScreen(button.convert(button.bounds, to: nil)) }
        placementScreen = button?.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen = placementScreen else { return }
        let frame = detachedPanelFrame(contentSize: panelContentSize, screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame, statusItemFrame: iconFrame)
        panel.setFrame(frame, display: true)
        updateDocumentSize(scrollOffset: scrollOffset)
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible { panel.makeFirstResponder(nil) }
    }

    func close() {
        // Ordering out a modal editor's parent also hides the child while its
        // modal run loop continues. Let that editor finish its own lifecycle.
        guard !presentingShortcutEditor, NSApp.modalWindow == nil else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        removeMonitors()
        if model.hasSettingsDraft || model.endTimeInputInvalid { model.discardSettingsDraft() }
    }

    func presentShortcutEditor(_ present: (NSWindow) -> Bool) -> Bool {
        guard !presentingShortcutEditor, NSApp.modalWindow == nil else { return false }
        let restorePanel = panel.isVisible
        // Cover activation/reopen events before runModal has set modalWindow.
        presentingShortcutEditor = true
        panel.orderOut(nil)
        removeMonitors()
        defer {
            presentingShortcutEditor = false
            if restorePanel { show() }
        }
        return present(panel)
    }

    private func updateSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        let next = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard next != naturalSize else { return }
        naturalSize = next
        if panel.isVisible { resizeVisiblePanel() }
        else { updateDocumentSize(scrollOffset: 0) }
    }

    private var panelContentSize: NSSize {
        NSSize(width: naturalSize.width, height: naturalSize.height + footerHeight.constant)
    }

    private func updateFooter() {
        let height = footer.rootView.preferredHeight
        guard height != footerHeight.constant else { return }
        footerHeight.constant = height
        if panel.isVisible { resizeVisiblePanel() }
    }

    private func resizeVisiblePanel() {
        guard panel.isVisible, let screen = panel.screen ?? placementScreen ?? NSScreen.main else { return }
        let frame = detachedPanelFrame(contentSize: panelContentSize, screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame, statusItemFrame: nil, previousFrame: panel.frame)
        let scrollOffset = scrollDistanceFromTop
        // Resize the window and its scroll viewport before drawing the new footer.
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        updateDocumentSize(scrollOffset: scrollOffset)
        panel.displayIfNeeded()
    }

    private var scrollDistanceFromTop: CGFloat {
        let visible = scrollView.documentVisibleRect
        let document = hosting.view.bounds
        return max(0, hosting.view.isFlipped ? visible.minY - document.minY : document.maxY - visible.maxY)
    }

    private func updateDocumentSize(scrollOffset: CGFloat) {
        hosting.view.setFrameSize(naturalSize)
        scrollView.hasVerticalScroller = panelContentSize.height > panel.contentLayoutRect.height + 0.5
        panel.contentView?.layoutSubtreeIfNeeded()
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
                if event.keyCode == 53 { self.close(); return nil }
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
