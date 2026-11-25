import SwiftUI

// The current session takes priority over the update link.
struct SessionStatusView: View {
    @ObservedObject var model: SessionModel
    let releaseURL: URL?
    @Environment(\.locale) private var locale
    @ObservedObject private var localization = AppLocalization.shared

    private var showsSessionStatus: Bool { model.phase == .active || model.isRestarting }

    func title(using clock: StopTimeInput.Clock) -> String {
        model.endDate.map { localizedFormat("Active until %@", clock.time($0, dateDetail: .full)) }
            ?? localized("Until stopped manually")
    }

    var body: some View {
        Group {
            if showsSessionStatus {
                Text(title(using: StopTimeInput.Clock(locale: locale)))
                    .monospacedDigit()
                    .foregroundStyle(Color(AppStyle.Color.success))
                    .accessibilityIdentifier("WakecupSessionStatus")
            } else if !model.busy, !model.needsRecovery, !model.needsBrightnessRecovery, let releaseURL {
                Link(localization.text("Update available"), destination: releaseURL)
                    .foregroundStyle(Color(nsColor: .linkColor))
            } else {
                Color.clear.frame(width: 0, height: AppStyle.Layout.headerStatusHeight)
                    .accessibilityHidden(true)
            }
        }
        .font(Font(AppStyle.Font.statusText))
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: AppStyle.Layout.headerStatusHeight)
    }
}
