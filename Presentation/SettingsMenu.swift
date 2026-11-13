import AppKit
import SwiftUI

private final class SettingsIconButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let previousRing = focusRingType
        focusRingType = .none
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        window?.makeFirstResponder(nil)
        focusRingType = previousRing
    }
}

struct SettingsMenu: NSViewRepresentable {
    let model: SessionModel
    let showAbout: () -> Void
    @ObservedObject private var localization = AppLocalization.shared

    func makeCoordinator() -> Coordinator { Coordinator(model: model, showAbout: showAbout) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = SettingsIconButton(frame: .zero, pullsDown: true)
        button.menu = context.coordinator.makeMenu()
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.controlSize = .small
        button.font = AppStyle.Font.body
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.toolTip = localized("Wakecup Settings")
        button.setAccessibilityLabel(localized("Wakecup Settings"))
        context.coordinator.refresh()
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        let model: SessionModel
        let showAbout: () -> Void
        private let remainingItem = NSMenuItem()
        private let loginItem = NSMenuItem()
        private let languageItem = NSMenuItem()
        private let aboutItem = NSMenuItem()
        private let quitItem = NSMenuItem()
        private let languageMenu = NSMenu()
        private let helperMenu = NSMenu()
        private let helperItem = NSMenuItem()
        private let passwordItem = NSMenuItem()
        private let installedItem = NSMenuItem()
        private let installItem = NSMenuItem()
        private let removeItem = NSMenuItem()
        private let helperExplanationItem = NSMenuItem()

        init(model: SessionModel, showAbout: @escaping () -> Void) {
            self.model = model; self.showAbout = showAbout
        }
        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.font = AppStyle.Font.body
            languageMenu.font = menu.font
            helperMenu.font = menu.font
            helperMenu.autoenablesItems = false
            passwordItem.action = #selector(selectPasswordMode)
            installedItem.action = #selector(selectHelperMode)
            installItem.action = #selector(installHelper)
            removeItem.action = #selector(removeHelper)
            helperExplanationItem.action = #selector(explainHelper)
            for item in [passwordItem, installedItem, installItem, removeItem, helperExplanationItem] { item.target = self }
            for item in [passwordItem, installedItem, .separator(), installItem, removeItem, .separator(), helperExplanationItem] { helperMenu.addItem(item) }
            helperItem.submenu = helperMenu
            menu.delegate = self
            let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            title.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: AppStyle.Icon.settingsPointSize, weight: .regular))
            menu.addItem(title)
            remainingItem.action = #selector(toggleRemaining)
            loginItem.action = #selector(toggleLogin)
            aboutItem.action = #selector(openAbout)
            quitItem.action = #selector(quit)
            for item in [remainingItem, loginItem, aboutItem, quitItem] { item.target = self }
            for language in AppLanguage.allCases {
                let item = NSMenuItem(title: language.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = language.rawValue
                languageMenu.addItem(item)
            }
            languageItem.submenu = languageMenu
            for item in [remainingItem, loginItem, languageItem, helperItem, .separator(), aboutItem, .separator(), quitItem] {
                menu.addItem(item)
            }
            refresh()
            return menu
        }
        func refresh() {
            remainingItem.title = localized("Show remaining time in menu bar")
            remainingItem.state = model.showRemaining ? .on : .off
            loginItem.title = localized(model.loginNeedsApproval ? "Allow login item in macOS…" : "Open at Login")
            loginItem.state = model.loginEnabled ? .on : .off
            languageItem.title = localized("Language")
            helperItem.title = localized("Closed-lid permission")
            passwordItem.title = localized("Ask for a password each session")
            passwordItem.state = model.helper.selected ? .off : .on
            passwordItem.isEnabled = model.canSelectHelperMode
            installedItem.title = localized("Use installed helper")
            installedItem.state = model.helper.selected ? .on : .off
            installedItem.isEnabled = model.canSelectHelperMode && model.helper.state == .ready
            installItem.title = localized(model.helper.working ? "Changing helper…" : model.helper.installed ? "Update helper…" : "Install helper…")
            installItem.isEnabled = model.canChangeHelper
            removeItem.title = localized("Remove helper…")
            removeItem.isEnabled = model.canChangeHelper && model.helper.installed
            helperExplanationItem.title = localized("Why install a helper?")
            aboutItem.title = localized("About Wakecup…")
            quitItem.title = localized("Quit Wakecup")
            for item in languageMenu.items {
                item.state = item.representedObject as? String == AppLocalization.shared.language.rawValue ? .on : .off
            }
        }
        func menuWillOpen(_ menu: NSMenu) { model.refreshLoginState(); model.helper.refresh(); refresh() }
        @objc private func selectPasswordMode() { guard model.canSelectHelperMode else { return }; model.helper.select(false) }
        @objc private func selectHelperMode() { guard model.canSelectHelperMode else { return }; model.helper.select(true) }
        @objc private func installHelper() { guard model.canChangeHelper else { return }; model.helper.changeInstallation(remove: false) }
        @objc private func removeHelper() { guard model.canChangeHelper else { return }; model.helper.changeInstallation(remove: true) }
        @objc private func explainHelper() { model.helper.showExplanation() }
        @objc private func toggleRemaining() { model.showRemaining.toggle() }
        @objc private func toggleLogin() { model.toggleLogin() }
        @objc private func openAbout() { showAbout() }
        @objc private func selectLanguage(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
            AppLocalization.shared.select(language)
            model.statusDidChange?()
        }
        @objc private func quit() { model.quit() }
    }
}
