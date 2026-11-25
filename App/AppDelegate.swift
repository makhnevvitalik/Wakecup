import AppKit
import Combine
import CoreServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SessionModel()
    private lazy var automation = AutomationController(model: model)
    private var menuPanel: MenuPanelController!
    private let sleepHelp = SleepHelpWindowController()
    private let mcpSetup = MCPSetupWindowController()
    private let updates = UpdateChecker()
    private lazy var about = AboutWindowController(updates: updates)
    var status: NSStatusItem!
    private let statusBadge = StatusBadge()
    private var statusIconObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private lazy var statusImages = Dictionary(uniqueKeysWithValues: StatusIconState.allCases.map {
        ($0, makeStatusIcon(state: $0))
    })

    func receiveAutomation(_ envelope: AutomationEnvelope) -> AutomationReply {
        automation.receive(envelope)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        NSApp.setActivationPolicy(.accessory)
        model.quitRequested = { NSApp.terminate(nil) }
        let autosaveName = "Wakecup"
        let positionKey = "NSStatusItem Preferred Position " + autosaveName
        // Seed a visible position once; AppKit saves later positions chosen by the user.
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.autosaveName = autosaveName
        status.isVisible = model.showInMenuBar
        status.button?.contentTintColor = nil
        status.button?.font = AppStyle.Font.menuBarCountdown
        status.button?.target = self
        status.button?.action = #selector(toggle)
        status.button?.toolTip = "Wakecup"
        if let button = status.button {
            statusBadge.frame = button.bounds
            statusBadge.autoresizingMask = [.width, .height]
            statusBadge.isHidden = true
            statusBadge.setAccessibilityElement(false)
            button.addSubview(statusBadge)
        }
        let helperPresentation = HelperPresentation(settingsOwner: { [weak self] in self?.menuPanel.settingsSheetOwner() })
        helperPresentation.observeRecovery(of: model)
        var helperInteraction = helperPresentation.interaction
        helperInteraction.dismissPanel = { [weak self] in self?.menuPanel.close() }
        helperInteraction.leaveForExplanation = { [weak self] in self?.menuPanel.leaveForAuxiliaryWindow() }
        menuPanel = MenuPanelController(model: model, updates: updates,
            statusButton: { [weak self] in self?.status?.button }, showHelp: { [weak self] in
                self?.menuPanel.close()
                self?.sleepHelp.show()
            }, showAbout: { [weak self] in
                guard let self else { return }
                self.about.show(returningTo: self.menuPanel.leaveForAuxiliaryWindow())
            }, showMCPSetup: { [weak self] in
                self?.menuPanel.close()
                self?.mcpSetup.show()
            }, configureDisplayShortcut: { [weak self] requiresShortcut, completion in
                guard let self else { completion(false); return }
                self.menuPanel.configureDisplayShortcut(requiresShortcut: requiresShortcut, completion: completion)
            }, helperInteraction: helperInteraction,
            isMCPEnabled: { [weak self] in self?.automation.mcpEnabled ?? false },
            setMCPEnabled: { [weak self] enabled in self?.automation.mcpEnabled = enabled })
        model.statusDidChange = { [weak self] in self?.updateStatus() }
        model.showRequested = { [weak self] in self?.showSessionFeedback() }
        updateStatus()
        if CommandLine.arguments.contains("--status-diagnostics") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let item = self?.status else { return }
                print("Wakecup status: bundle=\(Bundle.main.bundleIdentifier ?? "unknown") visible=\(item.isVisible) frame=\(String(describing: item.button?.window?.frame)) image=\(String(describing: item.button?.image?.size))")
                fflush(stdout)
            }
        }
        statusIconObservation = updates.$availableRelease.map { $0 != nil }.removeDuplicates()
            .combineLatest(model.helperStatuses.map(\.updateRequired).removeDuplicates())
            .sink { [weak self] hasUpdate, helperNeedsUpdate in
                self?.updateStatusIcon(hasUpdate: hasUpdate, helperNeedsUpdate: helperNeedsUpdate)
            }
        languageObservation = AppLocalization.shared.$language.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
        updates.startAutomaticChecks()
        if !launchedAtLogin, !CommandLine.arguments.contains("--automation-launch") { show() }
    }

    func updateStatus() {
        if let status, status.isVisible != model.showInMenuBar {
            status.isVisible = model.showInMenuBar
            if !model.showInMenuBar, menuPanel.isVisible {
                menuPanel.showWindow()
            }
        }
        let running = model.statusPhase == .active || model.isRestarting
        status?.length = running && model.showRemaining ? NSStatusItem.variableLength : NSStatusItem.squareLength
        if running, model.showRemaining {
            if let seconds = model.remaining {
                status?.button?.title = seconds >= 3600 ? " " + localizedFormat("%dh", Int(ceil(Double(seconds) / 3600))) : " " + localizedFormat("%dm", max(1, Int(ceil(Double(seconds) / 60))))
            } else { status?.button?.title = " ∞" }
        } else { status?.button?.title = "" }
        updateStatusIcon(hasUpdate: updates.availableRelease != nil,
                         helperNeedsUpdate: model.helperStatus.updateRequired)
    }

    private func updateStatusIcon(hasUpdate: Bool, helperNeedsUpdate: Bool) {
        let notice = StatusIconNotice(needsBrightnessRecovery: model.needsBrightnessRecovery,
                                      needsSleepRecovery: model.needsRecovery,
                                      helperNeedsUpdate: helperNeedsUpdate, hasAppUpdate: hasUpdate)
        let state = StatusIconState(phase: model.isRestarting ? .active : model.statusPhase, notice: notice)
        guard let button = status?.button else { return }
        button.image = statusImages[state]
        statusBadge.color = state.badgeColor
        let description = localized(notice.titleKey)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc func toggle() {
        model.refreshLoginState()
        menuPanel.isVisible ? menuPanel.close() : menuPanel.show()
    }
    private func showSessionFeedback() {
        guard !menuPanel.isVisible else { return }
        show()
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginState() }
    func show() {
        model.refreshLoginState()
        menuPanel.showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.refreshLoginState()
        menuPanel.reopen()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waiting = model.prepareToQuit {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return waiting ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
