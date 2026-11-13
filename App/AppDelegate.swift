import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SessionModel()
    private var menuPanel: MenuPanelController!
    private let sleepHelp = SleepHelpWindowController()
    private let about = AboutWindowController()
    var status: NSStatusItem!
    private lazy var inactiveStatusImage = makeStatusIcon(active: false)
    private lazy var activeStatusImage = makeStatusIcon(active: true)
    private lazy var attentionStatusImage = makeStatusIcon(state: .attention)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.helper.interaction = HelperPresentation.system.interaction
        model.quitRequested = { NSApp.terminate(nil) }
        let autosaveName = "Wakecup"
        let positionKey = "NSStatusItem Preferred Position " + autosaveName
        // Seed a visible position once; AppKit saves later positions chosen by the user.
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.autosaveName = autosaveName
        status.isVisible = true
        status.button?.contentTintColor = nil
        status.button?.font = AppStyle.Font.menuBarCountdown
        status.button?.target = self
        status.button?.action = #selector(toggle)
        status.button?.toolTip = "Wakecup"
        menuPanel = MenuPanelController(model: model,
            statusButton: { [weak self] in self?.status?.button }, showHelp: { [weak self] in
                self?.menuPanel.close()
                self?.sleepHelp.show()
            }, showAbout: { [weak self] in
                self?.menuPanel.close()
                self?.about.show()
            }, configureDisplayShortcut: { [weak self] requiresShortcut in
                guard let self else { return false }
                return self.menuPanel.presentShortcutEditor { owner in
                    DisplayShortcutEditor.present(model: self.model, owner: owner, requiresShortcut: requiresShortcut)
                }
            })
        model.statusDidChange = { [weak self] in self?.updateStatus() }
        model.showRequested = { [weak self] in self?.show() }
        updateStatus()
        if CommandLine.arguments.contains("--status-diagnostics") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let item = self?.status else { return }
                print("Wakecup status: bundle=\(Bundle.main.bundleIdentifier ?? "unknown") visible=\(item.isVisible) frame=\(String(describing: item.button?.window?.frame)) image=\(String(describing: item.button?.image?.size))")
                fflush(stdout)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.show() }
    }

    func updateStatus() {
        let running = model.phase == .active || model.isRestarting
        status?.length = running && model.showRemaining ? NSStatusItem.variableLength : NSStatusItem.squareLength
        status?.button?.contentTintColor = nil
        let iconState = StatusIconState(phase: model.isRestarting ? .active : model.phase, needsRecovery: model.needsRecovery)
        switch iconState {
        case .inactive: status?.button?.image = inactiveStatusImage
        case .active: status?.button?.image = activeStatusImage
        case .attention: status?.button?.image = attentionStatusImage
        }
        let description = model.needsRecovery ? localized("Wakecup — restore normal sleep") : "Wakecup"
        status?.button?.toolTip = description
        status?.button?.setAccessibilityLabel(description)
        if running, model.showRemaining {
            if let seconds = model.remaining {
                status?.button?.title = seconds >= 3600 ? " " + localizedFormat("%dh", Int(ceil(Double(seconds) / 3600))) : " " + localizedFormat("%dm", max(1, Int(ceil(Double(seconds) / 60))))
            } else { status?.button?.title = " ∞" }
        } else { status?.button?.title = "" }
    }

    @objc func toggle() { menuPanel.isVisible ? menuPanel.close() : show() }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginState() }
    func show() {
        model.refreshLoginState()
        menuPanel.show()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waiting = model.prepareToQuit {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return waiting ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
