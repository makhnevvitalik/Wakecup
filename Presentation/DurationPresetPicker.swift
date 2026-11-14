import AppKit
import SwiftUI

// Quick actions fill the concrete end time; selection belongs to the time row.
struct DurationPresetPicker: NSViewRepresentable {
    @ObservedObject var model: SessionModel
    private let presets = [60, 180, 300, 0]

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["", "", "", "∞"], trackingMode: .momentary,
            target: context.coordinator, action: #selector(Coordinator.selectPreset(_:)))
        control.controlSize = .small
        control.font = AppStyle.Font.controlLabel
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for (index, preset) in presets.enumerated() { control.setTag(preset, forSegment: index) }
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        control.isEnabled = context.environment.isEnabled
        for (index, title) in [localized("1 hour"), localized("3 hours"), localized("5 hours"), "∞"].enumerated() {
            control.setLabel(title, forSegment: index)
        }
        control.setAccessibilityLabel(localized("Duration"))
        control.setToolTip(localized("Until stopped manually"), forSegment: 3)
        control.selectedSegment = -1
    }

    final class Coordinator: NSObject {
        private let model: SessionModel
        init(model: SessionModel) { self.model = model }

        @objc func selectPreset(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0 else { return }
            let preset = sender.tag(forSegment: sender.selectedSegment)
            AppStyle.commitActiveFieldEditor(in: sender.window)
            model.selectEndTimePreset(preset)
        }
    }
}
