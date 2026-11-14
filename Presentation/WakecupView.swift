import SwiftUI

struct WakecupView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var updates: UpdateChecker
    let showAbout: () -> Void
    let configureDisplayShortcut: (Bool) -> Bool
    let showMCPSetup: () -> Void
    let helperInteraction: HelperInteraction
    let isMCPEnabled: () -> Bool
    let setMCPEnabled: (Bool) -> Void

    init(model: SessionModel, updates: UpdateChecker? = nil, showAbout: @escaping () -> Void, configureDisplayShortcut: @escaping (Bool) -> Bool,
         showMCPSetup: @escaping () -> Void = {}, helperInteraction: HelperInteraction = .init(),
         isMCPEnabled: @escaping () -> Bool = { false }, setMCPEnabled: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        self.updates = updates ?? UpdateChecker()
        self.showAbout = showAbout
        self.configureDisplayShortcut = configureDisplayShortcut
        self.showMCPSetup = showMCPSetup
        self.helperInteraction = helperInteraction
        self.isMCPEnabled = isMCPEnabled
        self.setMCPEnabled = setMCPEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Layout.cardSpacing) {
            header
            SessionActionsView(model: model)
            SessionOptionsView(model: model, configureDisplayShortcut: configureDisplayShortcut, helperInteraction: helperInteraction)
        }
        .padding(AppStyle.Layout.panelInset).frame(width: MenuLayout.width).font(Font(AppStyle.Font.body)).controlSize(.small).tint(Color(AppStyle.Color.accent))
    }

    private var releaseURL: URL? {
        guard case let .finished(.updateAvailable(_, url)) = updates.state else { return nil }
        return url
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
                SessionStatusView(model: model, releaseURL: releaseURL)
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
