import SwiftUI

struct WakecupView: View {
    @ObservedObject var model: SessionModel
    let showAbout: () -> Void
    let configureDisplayShortcut: (Bool) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.spacing) {
            header
            SessionActionsView(model: model)
            SessionOptionsView(model: model, configureDisplayShortcut: configureDisplayShortcut)
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
            SettingsMenu(model: model, showAbout: showAbout).frame(width: MenuLayout.settingsWidth, height: MenuLayout.settingsHeight)
        }.padding(.horizontal, 4).frame(height: MenuLayout.headerHeight)
    }

}
