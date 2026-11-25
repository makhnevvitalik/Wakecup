import AppKit
import SwiftUI

struct SessionOptionsView: View {
    @ObservedObject var model: SessionModel
    let configureDisplayShortcut: (Bool, @escaping (Bool) -> Void) -> Void
    let helperInteraction: HelperInteraction
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        StopTimeCard(model: model)
        MenuCard {
            MenuSectionHeading(title: localized("Mode"), symbol: "slider.horizontal.3")
            MenuToggleRow(title: localized("Keep awake with lid closed"), isOn: Binding(get: { model.selectedClosedLid }, set: model.editClosedLid),
                help: (localized("closed.lid.help"), localized("Help about closed-lid mode"), "WakecupClosedLidInfo"))
                .disabled(!model.canChangeClosedLid)
            helperRow
            Divider()
            MenuToggleRow(title: localized("Keep awake on battery"), isOn: Binding(get: { model.selectedAllowBattery }, set: model.editAllowBattery),
                help: (localized("battery.power.help"), localized("Help about battery power"), "WakecupBatteryPowerInfo"))
                .disabled(!model.canEditSettingsDraft)
            batteryThreshold
                .disabled(!model.canEditSettingsDraft)
            Divider()
            thermalStopControl
            Divider()
            displayControls
        }
    }

    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                settingLabel("Display backlight", help: "display.modes.help", helpLabel: "Help about display mode", identifier: "WakecupDisplayModeInfo")
                SessionOptionPicker(selection: Binding(get: { model.displayModeDraft ?? model.displayMode }, set: selectDisplayMode),
                    options: [(DisplayMode.mayTurnOff, "May turn off"), (.keepOn, "Keep on"), (.backlightOff, "Backlight off")],
                    label: "Display backlight", identifier: "WakecupDisplayMode", enabled: model.canChangeDisplayMode)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: MenuLayout.compactControlHeight)
            }.frame(height: 24)
            shortcutRow
        }.padding(.horizontal, AppStyle.Layout.cardInset).padding(.vertical, 10)
    }

    private var shortcutRow: some View {
        let shortcut = model.displayShortcut
        let value = shortcut?.displayName ?? localized("Not assigned")
        let detail = shortcut.map { localizedFormat("Current shortcut: %@", $0.displayName) } ?? value
        let action = shortcut == nil ? "Configure…" : "Change…"
        let accessibilityAction = shortcut == nil ? "Configure backlight shortcut" : "Change backlight shortcut"
        return HStack(spacing: AppStyle.Layout.rowItemSpacing) {
            VStack(alignment: .leading, spacing: MenuLayout.detailSpacing) {
                settingLabel("Backlight shortcut", help: "display.shortcut.summary", helpLabel: "Help about the backlight shortcut", identifier: "WakecupDisplayShortcutInfo")
                Text(detail)
                    .font(Font(AppStyle.Font.supportingText))
                    .foregroundStyle(Color(nsColor: AppStyle.Color.stateDetailText))
                    .accessibilityHidden(true)
            }
            CompactCommandButton(title: localized(action), accessibilityTitle: localized(accessibilityAction),
                value: value, help: localized("display.shortcut.explanation"), identifier: "WakecupConfigureDisplayShortcut",
                isEnabled: model.canChangeDisplayShortcut) {
                    configureDisplayShortcut(false) { _ in }
                }
        }.frame(minHeight: AppStyle.Layout.rowHeight)
    }

    private var thermalStopControl: some View {
        HStack(spacing: 8) {
            settingLabel("Stop when hot", help: "thermal.stop.help", helpLabel: "Help about the thermal threshold", identifier: "WakecupThermalStopInfo")
            SessionOptionPicker(selection: Binding(get: { model.thermalStopLevel }, set: model.setThermalStopLevel),
                options: [(ThermalStopLevel.critical, "Critical"), (.serious, "Serious")],
                label: "Stop when hot", identifier: "WakecupThermalStopLevel", enabled: true)
                .frame(width: 142, height: MenuLayout.compactControlHeight)
        }.frame(minHeight: AppStyle.Layout.rowHeight).padding(.horizontal, AppStyle.Layout.cardInset).padding(.vertical, 6)
    }

    private func settingLabel(_ title: String, help: String, helpLabel: String, identifier: String) -> some View {
        HStack(spacing: 5) {
            Text(localized(title)).font(Font(AppStyle.Font.body))
            MenuInfoButton(text: localized(help), accessibilityTitle: localized(helpLabel), identifier: identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectDisplayMode(_ mode: DisplayMode) {
        model.selectDisplayMode(mode) { complete in
            configureDisplayShortcut(true, complete)
        }
    }

    private var helperRow: some View {
        let helper = model.helperStatus
        let presentation = HelperStatusPresentation(state: helper.state, selected: helper.selected,
            working: helper.working, checking: helper.checking)
        let canAct = !helper.checking && (presentation.action.changesInstallation
            ? model.canChangeHelper : model.canSelectHelperMode)
        return HelperStatusRow(presentation: presentation, actionEnabled: canAct) {
            guard canAct else { return }
            switch presentation.action {
            case .install, .update: helperInteraction.changeInstallation(for: model, remove: false)
            case .settings, .details:
                helperInteraction.showSettings(for: model)
            }
        }
    }

    private var batteryThreshold: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(localized("Stop at battery level")).font(Font(AppStyle.Font.body))
                Spacer()
                Text(localizedFormat("%d%% or lower", Int(model.selectedThreshold)))
                    .font(Font(AppStyle.Font.emphasizedBody)).monospacedDigit()
            }.foregroundStyle(model.selectedAllowBattery ? Color.primary : Color.secondary)
            BatteryLevelControl(threshold: Binding(get: { model.selectedThreshold }, set: model.editThreshold),
                charge: model.power?.percent, thresholdEnabled: model.selectedAllowBattery)
                .frame(height: 40)
        }.padding(.horizontal, AppStyle.Layout.cardInset).padding(.vertical, 10)
    }
}

// A native menu retains the same geometry for every selected mode and uses the
// same AppStyle font as the rest of the settings. Model setters own all effects.
private struct SessionOptionPicker<Value: Equatable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let label: String
    let identifier: String
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        // The model owns the checkmark even when the native choice is rejected.
        (control.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        control.controlSize = .small
        control.font = AppStyle.Font.controlLabel
        control.menu?.font = AppStyle.Font.body
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.target = context.coordinator
        control.action = #selector(Coordinator.select(_:))
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map { localized($0.title) }
        if control.itemTitles != titles { control.removeAllItems(); control.addItems(withTitles: titles) }
        context.coordinator.syncSelection(in: control)
        control.isEnabled = enabled
        control.setAccessibilityLabel(localized(label))
    }
    final class Coordinator: NSObject {
        var parent: SessionOptionPicker
        init(_ parent: SessionOptionPicker) { self.parent = parent }
        @objc func select(_ control: NSPopUpButton) {
            let index = control.indexOfSelectedItem
            if parent.enabled, parent.options.indices.contains(index) {
                parent.selection = parent.options[index].value
            }
            syncSelection(in: control)
        }

        func syncSelection(in control: NSPopUpButton) {
            let selected = parent.options.firstIndex { $0.value == parent.selection } ?? 0
            control.selectItem(at: selected)
            for (index, item) in control.itemArray.enumerated() {
                item.state = index == selected ? .on : .off
            }
        }
    }
}
