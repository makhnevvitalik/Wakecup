import AppKit
import SwiftUI

struct StopTimeCard: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var localization = AppLocalization.shared
    @State private var calendarRequest: CalendarRequest?
    @State private var editingTime = false

    private struct CalendarRequest: Identifiable {
        let id = UUID()
        let date: Date
        let now: Date
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: localization.language.rawValue)
        return calendar
    }
    private var visibleIssue: EndTimeSelection.Issue? {
        let issue = model.endTimeIssue
        return editingTime && issue == .incomplete ? nil : issue
    }

    private var caption: String {
        if let issue = visibleIssue { return localized(issue.messageKey) }
        if model.endTimeInputInvalid { return "" }
        guard let date = model.selectedEndDate else { return localized("Until stopped manually") }
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        let remaining = max(1, ceil(date.timeIntervalSince(model.currentDate)))
        formatter.allowedUnits = remaining < 60 ? [.second] : [.day, .hour, .minute]
        formatter.maximumUnitCount = 2; formatter.unitsStyle = .abbreviated
        let seconds = remaining < 60 ? remaining : ceil(remaining / 60) * 60
        return localizedFormat("Stops in %@", formatter.string(from: seconds) ?? "")
    }
    var body: some View {
        MenuCard {
            MenuSectionHeading(title: localized("When to stop"), symbol: "clock")
            DurationPresetPicker(model: model)
                .frame(height: MenuLayout.compactControlHeight)
                .padding(.horizontal, MenuLayout.inset).padding(.bottom, 12)
            HStack(spacing: 8) {
                Text(localized("Stop at")).font(Font(AppStyle.Font.body))
                Spacer(minLength: 4)
                EndDayPicker(date: model.selectedEndDate, now: model.currentDate, calendar: calendar,
                    select: selectDay, selectUnlimited: {
                        commitInput(); model.selectEndTimePreset(0)
                    }, chooseDate: {
                        commitInput()
                        let now = model.currentDate
                        calendarRequest = CalendarRequest(date: model.selectedEndDate ?? now, now: now)
                    }).frame(width: 105, height: 26)
                    .popover(item: $calendarRequest) { request in
                        CalendarDayPicker(date: request.date, now: request.now, calendar: calendar) { day in
                                selectDay(day); calendarRequest = nil
                            }.padding(MenuLayout.tooltipPadding)
                    }
                StopTimeField(date: model.selectedEndDate, day: model.selectedEndDay, now: model.currentDate, calendar: calendar,
                    invalid: model.endTimeInputInvalid, select: model.selectEndDate, validation: model.setEndTimeInputInvalid, editingChanged: { editingTime = $0 })
                    .frame(width: 94, height: 26)
            }.padding(.horizontal, MenuLayout.inset)
            HStack(spacing: 6) {
                Text(caption)
                    .foregroundStyle(visibleIssue == nil ? Color.secondary : Color.red)
                if visibleIssue == .past {
                    Button(localized("Tomorrow")) {
                        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: model.currentDate) { selectDay(tomorrow) }
                    }.buttonStyle(.link).controlSize(.small)
                        .accessibilityIdentifier("WakecupChooseTomorrow")
                }
            }.font(Font(AppStyle.Font.supportingText))
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
                .padding(.horizontal, MenuLayout.inset)
                .padding(.top, MenuLayout.detailSpacing).padding(.bottom, 10)
                .accessibilityIdentifier("WakecupStopTimeCaption")
        }.disabled(!model.canEditSettingsDraft)
    }
    private func selectDay(_ day: Date) {
        commitInput()
        model.selectEndDay(day, calendar: calendar)
    }
    private func commitInput() { NSApp.keyWindow?.makeFirstResponder(nil) }
}

private struct EndDayPicker: NSViewRepresentable {
    let date: Date?
    let now: Date
    let calendar: Calendar
    let select: (Date) -> Void
    let selectUnlimited: () -> Void
    let chooseDate: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: false)
        // The checkmark follows the model, including when the calendar is cancelled.
        (view.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        view.font = AppStyle.Font.controlLabel; view.controlSize = .regular
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.identifier = NSUserInterfaceItemIdentifier("WakecupEndDay")
        view.target = context.coordinator; view.action = #selector(Coordinator.changed(_:))
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 105, height: 26)
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        view.isEnabled = enabled; view.setAccessibilityLabel(localized("End day"))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var titles = [localized("Today"), localized("Tomorrow"), localized("Indefinitely")]
        var selected = 0
        if let date {
            if calendar.isDate(date, inSameDayAs: tomorrow) { selected = 1 }
            else if !calendar.isDate(date, inSameDayAs: now) {
                let formatter = DateFormatter(); formatter.locale = calendar.locale; formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone; formatter.setLocalizedDateFormatFromTemplate("dMMM")
                titles.append(formatter.string(from: date)); selected = 3
            }
        } else { selected = 2 }
        titles.append(localized("Choose date…"))
        if view.itemTitles != titles { view.removeAllItems(); view.addItems(withTitles: titles) }
        context.coordinator.syncSelection(in: view, selected: selected)
    }
    final class Coordinator: NSObject {
        var parent: EndDayPicker
        private var selectedIndex = 0

        init(_ parent: EndDayPicker) { self.parent = parent }

        func syncSelection(in view: NSPopUpButton, selected: Int) {
            selectedIndex = selected
            view.selectItem(at: selected)
            for (index, item) in view.itemArray.enumerated() {
                item.state = index == selected ? .on : .off
            }
        }

        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            syncSelection(in: sender, selected: selectedIndex)
            guard sender.isEnabled, sender.itemArray.indices.contains(index) else { return }
            if index == sender.numberOfItems - 1 { parent.chooseDate() }
            else if index == 2 { parent.selectUnlimited() }
            else if index < 2 {
                let today = parent.calendar.startOfDay(for: parent.now)
                if let day = parent.calendar.date(byAdding: .day, value: index, to: today) {
                    parent.select(day)
                }
            }
        }
    }
}
