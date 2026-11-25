import AppKit
import SwiftUI

struct StopTimeCard: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.locale) private var locale
    @State private var calendarRequest: CalendarRequest?
    @State private var editingTime = false

    private struct CalendarRequest: Identifiable {
        let id = UUID()
        let date: Date
        let now: Date
    }

    private var clock: StopTimeInput.Clock { StopTimeInput.Clock(locale: locale) }
    private var visibleIssue: EndTimeSelection.Issue? {
        let issue = model.endTimeIssue
        return editingTime && issue == .incomplete ? nil : issue
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(1, interval.rounded())
        let formatter = DateComponentsFormatter()
        var durationCalendar = Calendar.current
        durationCalendar.locale = Locale(identifier: localization.language.rawValue)
        formatter.calendar = durationCalendar
        formatter.allowedUnits = seconds < 60 ? [.second] : [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds < 60 ? seconds : (seconds / 60).rounded() * 60) ?? ""
    }

    private func stopTime(_ date: Date, from now: Date, clock: StopTimeInput.Clock) -> String {
        switch clock.dayPresentation(for: date, relativeTo: now) {
        case .today: clock.time(date)
        case .tomorrow: localizedFormat("%@ tomorrow", clock.time(date))
        case .date(let detail): clock.time(date, dateDetail: detail)
        }
    }

    func caption(using clock: StopTimeInput.Clock) -> String {
        if let issue = visibleIssue {
            return issue == .incomplete ? localizedFormat("Enter a time such as %@.", clock.example(on: model.currentDate))
                : localized(issue.messageKey)
        }
        if model.endTimeInputInvalid { return "" }
        guard let date = model.selectedEndDate else { return localized("Until stopped manually") }
        let now = model.currentDate
        let interval: String
        if model.phase == .active, model.durationEditDirty, let applied = model.endDate,
           date.timeIntervalSince(applied).rounded() != 0 {
            let delta = date.timeIntervalSince(applied).rounded()
            interval = (delta > 0 ? "+" : "−") + durationText(abs(delta))
        } else {
            interval = durationText(date.timeIntervalSince(now))
        }
        return localizedFormat("Until %@ (%@)", stopTime(date, from: now, clock: clock), interval)
    }

    var body: some View {
        let clock = self.clock
        let calendar = clock.calendar
        let replacementID = model.endTimeReplacementID
        MenuCard {
            MenuSectionHeading(title: localized("Run time"), symbol: "clock")
            HStack(spacing: 6) {
                Text(caption(using: clock))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(visibleIssue == nil ? Color.primary : Color.red)
                if visibleIssue == .past {
                    Button(localized("Tomorrow")) {
                        if let tomorrow = clock.tomorrow(from: model.currentDate) { selectDay(tomorrow) }
                    }.buttonStyle(.link).controlSize(.small)
                        .accessibilityIdentifier("WakecupChooseTomorrow")
                }
            }.font(Font(visibleIssue == nil ? AppStyle.Font.emphasizedBody : AppStyle.Font.supportingText))
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .padding(.horizontal, AppStyle.Layout.cardInset)
                .padding(.bottom, 6)
                .accessibilityIdentifier("WakecupStopTimeCaption")
            DurationPresetPicker(model: model)
                .frame(height: MenuLayout.compactControlHeight)
                .padding(.horizontal, AppStyle.Layout.cardInset).padding(.bottom, 12)
            HStack(spacing: 8) {
                Text(localized(model.phase == .active && model.durationEditDirty ? "New stop time" : "Stop at")).font(Font(AppStyle.Font.body))
                Spacer(minLength: 4)
                EndDayPicker(date: model.selectedEndCalendarDate, now: model.currentDate, clock: clock,
                    select: selectDay, selectUnlimited: {
                        commitInput(); model.selectEndTimePreset(0)
                    }, chooseDate: {
                        commitInput()
                        let now = model.currentDate
                        calendarRequest = CalendarRequest(date: model.selectedEndCalendarDate ?? now, now: now)
                    }).frame(height: 26)
                    .popover(item: $calendarRequest) { request in
                        CalendarDayPicker(date: request.date, now: request.now, calendar: calendar) { day in
                                selectDay(day); calendarRequest = nil
                            }.padding(MenuLayout.tooltipPadding)
                    }
                StopTimeField(date: model.selectedEndDate, unresolvedTime: model.unresolvedEndClockTime,
                    day: model.selectedEndDay, now: model.currentDate, clock: clock,
                    invalid: model.endTimeInputInvalid, replacementID: replacementID, edit: { edit in
                        // The old editor can resign before SwiftUI renders an automation change.
                        guard replacementID == model.endTimeReplacementID else { return }
                        model.editEndClock(edit)
                    }, editingChanged: { editingTime = $0 })
                    .frame(height: 26)
            }.padding(.horizontal, AppStyle.Layout.cardInset)
                .padding(.bottom, 10)
        }.disabled(!model.canEditSettingsDraft)
    }
    private func selectDay(_ day: Date) {
        commitInput()
        model.selectEndDay(day, calendar: clock.calendar)
    }
    private func commitInput() { AppStyle.commitActiveFieldEditor(in: NSApp.keyWindow) }
}

private struct EndDayPicker: NSViewRepresentable {
    let date: Date?
    let now: Date
    let clock: StopTimeInput.Clock
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
        let minimumWidth: CGFloat = 105
        guard let date, case .date(let detail) = clock.dayPresentation(for: date, relativeTo: now) else {
            return CGSize(width: minimumWidth, height: 26)
        }
        let label = clock.dateLabel(date, detail: detail) as NSString
        let labelWidth = ceil(label.size(withAttributes: [.font: AppStyle.Font.controlLabel]).width)
        return CGSize(width: max(minimumWidth, labelWidth + 36), height: 26)
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        view.isEnabled = enabled; view.setAccessibilityLabel(localized("End day"))
        var titles = [localized("Today"), localized("Tomorrow"), localized("Indefinitely")]
        var selected = 2
        if let date {
            switch clock.dayPresentation(for: date, relativeTo: now) {
            case .today: selected = 0
            case .tomorrow: selected = 1
            case .date(let detail):
                titles.append(clock.dateLabel(date, detail: detail))
                selected = 3
            }
        }
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
            else if index == 0 { parent.select(parent.clock.calendar.startOfDay(for: parent.now)) }
            else if index == 1, let tomorrow = parent.clock.tomorrow(from: parent.now) {
                parent.select(tomorrow)
            }
        }
    }
}
