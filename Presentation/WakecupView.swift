import SwiftUI

struct WakecupView: View {
    @ObservedObject var model: SessionModel
    let showAbout: () -> Void
    let configureDisplayShortcut: (Bool) -> Bool
    let showMCPSetup: () -> Void
    let helperInteraction: HelperInteraction
    let isMCPEnabled: () -> Bool
    let setMCPEnabled: (Bool) -> Void

    init(model: SessionModel, showAbout: @escaping () -> Void, configureDisplayShortcut: @escaping (Bool) -> Bool,
         showMCPSetup: @escaping () -> Void = {}, helperInteraction: HelperInteraction = .init(),
         isMCPEnabled: @escaping () -> Bool = { false }, setMCPEnabled: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        self.showAbout = showAbout
        self.configureDisplayShortcut = configureDisplayShortcut
        self.showMCPSetup = showMCPSetup
        self.helperInteraction = helperInteraction
        self.isMCPEnabled = isMCPEnabled
        self.setMCPEnabled = setMCPEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.spacing) {
            header
            SessionActionsView(model: model)
            SessionOptionsView(model: model, configureDisplayShortcut: configureDisplayShortcut, helperInteraction: helperInteraction)
        }
        .padding(MenuLayout.panelInset).frame(width: MenuLayout.width).font(Font(AppStyle.Font.body)).controlSize(.small).tint(Color(AppStyle.Color.accent))
    }

    private var header: some View {
        HStack(spacing: MenuLayout.rowSpacing) {
            Image(nsImage: WakecupBrand.appIcon).resizable().scaledToFit()
                .frame(width: AppStyle.Icon.brandSize.width, height: AppStyle.Icon.brandSize.height)
                .frame(width: MenuLayout.brandIconFrame, height: MenuLayout.brandIconFrame)
            VStack(alignment: .leading, spacing: MenuLayout.detailSpacing) {
                Text("Wakecup").font(Font(AppStyle.Font.appName))
                SessionStatusView(model: model)
            }.frame(maxWidth: .infinity, alignment: .leading)
            SettingsMenu(model: model, showAbout: showAbout, showMCPSetup: showMCPSetup, helperInteraction: helperInteraction,
                         isMCPEnabled: isMCPEnabled, setMCPEnabled: setMCPEnabled)
                .frame(width: MenuLayout.settingsWidth, height: MenuLayout.settingsHeight)
        }.padding(.horizontal, 4).frame(height: MenuLayout.headerHeight)
    }

}
