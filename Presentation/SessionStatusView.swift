import SwiftUI

// A fixed-height status line keeps the brand header stable across states.
// Idle needs no caption; the primary action already says that Wakecup can start.
struct SessionStatusView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var localization = AppLocalization.shared

    private var title: String {
        guard model.phase == .active || model.isRestarting else { return "" }
        return model.endDate.map { localizedFormat("Active until %@", endTime($0)) }
            ?? localized("Until stopped manually")
    }

    var body: some View {
        Text(title).font(Font(AppStyle.Font.statusText)).monospacedDigit()
            .foregroundStyle(Color(AppStyle.Color.success))
            .lineLimit(1)
            .accessibilityIdentifier("WakecupSessionStatus")
            .accessibilityHidden(title.isEmpty)
            .frame(height: MenuLayout.statusLineHeight)
    }

    private func endTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                                       time: .shortened).locale(Locale(identifier: localization.language.rawValue)))
    }
}
