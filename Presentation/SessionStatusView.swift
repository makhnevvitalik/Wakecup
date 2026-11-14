import SwiftUI

// The status line reserves room for ordinary state changes and wraps longer text.
// The current session takes priority over the update link.
struct SessionStatusView: View {
    @ObservedObject var model: SessionModel
    let releaseURL: URL?
    @ObservedObject private var localization = AppLocalization.shared

    private var showsSessionStatus: Bool { model.phase == .active || model.isRestarting }

    private var title: String {
        return model.endDate.map { localizedFormat("Active until %@", endTime($0)) }
            ?? localized("Until stopped manually")
    }

    var body: some View {
        Group {
            if showsSessionStatus {
                Text(title).monospacedDigit()
                    .foregroundStyle(Color(AppStyle.Color.success))
                    .accessibilityIdentifier("WakecupSessionStatus")
            } else if model.phase == .idle, let releaseURL {
                Link(localization.text("Update available"), destination: releaseURL)
                    .foregroundStyle(Color(nsColor: .linkColor))
            } else {
                Color.clear.frame(width: 0).accessibilityHidden(true)
            }
        }
        .font(Font(AppStyle.Font.statusText))
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: AppStyle.Layout.headerStatusHeight)
    }

    private func endTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                                       time: .shortened).locale(Locale(identifier: localization.language.rawValue)))
    }
}
