import AppKit
import SwiftUI

struct SessionOptionsView: View {
    @ObservedObject var model: SessionModel
    let configureDisplayShortcut: (Bool) -> Bool
    let helperInteraction: HelperInteraction
    @ObservedObject private var localization = AppLocalization.shared
    @State private var showingDisplayHint = false
    var body: some View {
        StopTimeCard(model: model)
        MenuCard {
            MenuSectionHeading(title: localized("Mode"), symbol: "slider.horizontal.3")
            MenuToggleRow(title: localized("Keep awake with lid closed"), isOn: Binding(get: { model.selectedClosedLid }, set: model.editClosedLid),
                hint: localized("closed.lid.help"))
                .disabled(!model.canChangeClosedLid)
            helperRow
            Divider()
            MenuToggleRow(title: localized("Keep awake on battery"), isOn: Binding(get: { model.selectedAllowBattery }, set: model.editAllowBattery),
                hint: localized("battery.power.help"))
                .disabled(!model.canEditSettingsDraft)
            batteryThreshold
                .disabled(!model.canEditSettingsDraft)
            Divider()
            displayControls

        }
    }

    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text(localized("Display backlight")).font(Font(AppStyle.Font.body))
                    Button { showingDisplayHint.toggle() } label: {
                        Image(systemName: "info.circle").font(Font(AppStyle.Font.supportingText)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localized("display.modes.help"))
                    .accessibilityLabel(localized("About this setting"))
                    .accessibilityIdentifier("WakecupDisplayModeInfo")
                    .popover(isPresented: $showingDisplayHint) {
                        MenuFeedbackPopover(text: localized("display.modes.help"))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                DisplayModePicker(selection: Binding(get: { model.displayModeDraft ?? model.displayMode }, set: selectDisplayMode),
                    enabled: model.canChangeDisplayMode)
                    .frame(width: 184, height: MenuLayout.compactControlHeight)
            }.frame(height: 24)
            MenuDetailRow {
                Text(localized("Restore brightness"))
            } detail: {
                Text(localized("Only in Backlight off mode"))
            } action: {
                Button(model.displayShortcut?.displayName ?? localized("Configure…")) {
                    _ = configureDisplayShortcut(false)
                }
                .help(localized("display.shortcut.explanation"))
                .accessibilityLabel(localized("Restore brightness shortcut"))
                .accessibilityValue(model.displayShortcut?.displayName ?? localized("Not configured"))
                .accessibilityIdentifier("WakecupConfigureDisplayShortcut")
            }.disabled(!model.canChangeDisplayShortcut)
        }.padding(.horizontal, MenuLayout.inset).padding(.vertical, 10)
    }

    private func selectDisplayMode(_ mode: DisplayMode) {
        DisplayShortcutEditor.selectMode(mode, model: model) {
            configureDisplayShortcut(true)
        }
    }

    private var helperRow: some View {
        let presentation = HelperStatusPresentation(state: model.helper.state, selected: model.helper.selected,
            working: model.helper.working, checking: model.helper.checking)
        let canAct = !model.helper.checking && (presentation.action.changesInstallation
            ? model.canChangeHelper : model.canSelectHelperMode)
        return HelperStatusRow(presentation: presentation, actionEnabled: canAct) {
            guard canAct else { return }
            switch presentation.action {
            case .install, .update: helperInteraction.changeInstallation(for: model.helper, remove: false)
            case .settings, .details:
                helperInteraction.showSettings(for: model.helper, allowInstallationChanges: model.canChangeHelper)
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
                .frame(height: 44)
        }.padding(.horizontal, MenuLayout.inset).padding(.vertical, 10)
    }
}

// A native menu retains the same geometry for every selected mode and uses the
// same AppStyle font as the rest of the settings. Model setters own all effects.
struct DisplayModePicker: NSViewRepresentable {
    @Binding var selection: DisplayMode
    var enabled: Bool
    private static let modes: [DisplayMode] = [.mayTurnOff, .keepOn, .backlightOff]
    private static let titles = ["May turn off", "Keep on", "Backlight off"]

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        // The model owns the checkmark even when the native choice is rejected.
        (control.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        control.controlSize = .small
        control.font = AppStyle.Font.controlLabel
        control.menu?.font = AppStyle.Font.body
        control.identifier = NSUserInterfaceItemIdentifier("WakecupDisplayMode")
        control.target = context.coordinator
        control.action = #selector(Coordinator.select(_:))
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = Self.titles.map(localized)
        if control.itemTitles != titles { control.removeAllItems(); control.addItems(withTitles: titles) }
        context.coordinator.syncSelection(in: control)
        control.isEnabled = enabled
        control.setAccessibilityLabel(localized("Display backlight"))
    }
    final class Coordinator: NSObject {
        var parent: DisplayModePicker
        init(_ parent: DisplayModePicker) { self.parent = parent }
        @objc func select(_ control: NSPopUpButton) {
            let index = control.indexOfSelectedItem
            if parent.enabled, DisplayModePicker.modes.indices.contains(index) {
                parent.selection = DisplayModePicker.modes[index]
            }
            syncSelection(in: control)
        }

        func syncSelection(in control: NSPopUpButton) {
            let selected = DisplayModePicker.modes.firstIndex(of: parent.selection) ?? 0
            control.selectItem(at: selected)
            for (index, item) in control.itemArray.enumerated() {
                item.state = index == selected ? .on : .off
            }
        }
    }
}
