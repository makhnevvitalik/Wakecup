import SwiftUI

struct WakecupHeaderView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var updates: UpdateChecker
    let showAbout: () -> Void
    let showMCPSetup: () -> Void
    let helperInteraction: HelperInteraction
    let isMCPEnabled: () -> Bool
    let setMCPEnabled: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Layout.cardSpacing) {
            header
            SessionActionsView(model: model)
        }
        .padding([.top, .horizontal], AppStyle.Layout.panelInset)
        .padding(.bottom, AppStyle.Layout.cardSpacing)
        .wakecupPanelContent()
    }

    private static let headerIcon = AppStyle.Icon.brandImage(WakecupBrand.appIcon, size: AppStyle.Icon.brandSize)

    private var header: some View {
        HStack(spacing: AppStyle.Layout.headerItemSpacing) {
            Image(nsImage: Self.headerIcon).resizable().scaledToFit()
                .frame(width: AppStyle.Icon.brandSize.width, height: AppStyle.Icon.brandSize.height)
                .frame(width: AppStyle.Layout.headerIconFrame, height: AppStyle.Layout.headerIconFrame)
            VStack(alignment: .leading, spacing: AppStyle.Layout.headerStatusSpacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: AppStyle.Layout.headerVersionSpacing) {
                        appName
                        version
                    }.fixedSize()
                    VStack(alignment: .leading, spacing: AppStyle.Layout.headerStatusSpacing) {
                        appName
                        version
                    }.fixedSize(horizontal: false, vertical: true)
                }
                SessionStatusView(model: model, releaseURL: updates.availableRelease?.url)
            }.frame(maxWidth: .infinity, alignment: .leading)
            SettingsMenu(model: model, showAbout: showAbout, showMCPSetup: showMCPSetup, helperInteraction: helperInteraction,
                         isMCPEnabled: isMCPEnabled, setMCPEnabled: setMCPEnabled)
                .frame(width: AppStyle.Layout.settingsButtonSize.width, height: AppStyle.Layout.settingsButtonSize.height)
        }
        .padding(.horizontal, AppStyle.Layout.headerHorizontalInset)
        .frame(minHeight: AppStyle.Layout.headerHeight)
    }

    private var appName: some View {
        Text("Wakecup").font(Font(AppStyle.Font.appName))
    }

    @ViewBuilder private var version: some View {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            Text(version).font(Font(AppStyle.Font.metadata)).foregroundStyle(.secondary)
        }
    }
}

struct WakecupOptionsView: View {
    let model: SessionModel
    let configureDisplayShortcut: (Bool, @escaping (Bool) -> Void) -> Void
    let helperInteraction: HelperInteraction

    var body: some View {
        SessionOptionsView(model: model, configureDisplayShortcut: configureDisplayShortcut, helperInteraction: helperInteraction)
            .padding([.horizontal, .bottom], AppStyle.Layout.panelInset)
            .wakecupPanelContent()
    }
}

private extension View {
    func wakecupPanelContent() -> some View {
        frame(width: MenuLayout.width)
            .font(Font(AppStyle.Font.body))
            .controlSize(.small)
            .tint(Color(AppStyle.Color.accent))
    }
}
