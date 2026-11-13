import SwiftUI

// The selected permission mode is user intent; readiness is the helper's health.
struct HelperStatusPresentation {
    enum Action: Equatable {
        case settings, install, update, details
        var changesInstallation: Bool { self == .install || self == .update }
        var titleKey: String {
            switch self {
            case .settings: "Configure…"
            case .install: "Install"
            case .update: "Update"
            case .details: "Details…"
            }
        }
        var accessibilityKey: String {
            switch self {
            case .install: "Install helper"
            case .update: "Update helper"
            case .settings, .details: "Wakecup helper"
            }
        }
    }
    let statusKey: String
    let descriptionKey: String
    let action: Action
    let needsAttention: Bool

    init(state: PrivilegedHelperController.State, selected: Bool, working: Bool, checking: Bool) {
        if working {
            statusKey = "Applying changes…"
            descriptionKey = "Wait for the operation to finish."
            action = .settings
            needsAttention = false
        } else if checking && selected {
            statusKey = "Checking readiness…"
            descriptionKey = "Wait for the check to finish."
            action = .settings
            needsAttention = false
        } else if !selected {
            statusKey = state == .missing ? "Not installed" : "Disabled in settings"
            descriptionKey = "Closed-lid mode requires a password."
            action = state == .missing ? .install : .settings
            needsAttention = false
        } else {
            needsAttention = state != .ready
            switch state {
            case .ready:
                statusKey = "Installed and in use"
                descriptionKey = "Closed-lid mode — no password required."
                action = .settings
            case .updateRequired:
                statusKey = "Update required"
                descriptionKey = "Closed-lid mode requires a password for now."
                action = .update
            case .unavailable:
                statusKey = "Unavailable"
                descriptionKey = "Closed-lid mode requires a password for now."
                action = .details
            case .missing:
                statusKey = "Not installed"
                descriptionKey = "Closed-lid mode requires a password."
                action = .install
            }
        }
    }
}

struct HelperStatusRow: View {
    let presentation: HelperStatusPresentation
    let actionEnabled: Bool
    let action: () -> Void
    @ObservedObject private var localization = AppLocalization.shared
    @State private var showingHint = false

    var body: some View {
        MenuDetailRow {
            HStack(spacing: MenuLayout.rowSpacing) {
                Text(localized("Helper"))
                Button { showingHint.toggle() } label: {
                    Image(systemName: "info.circle").font(Font(AppStyle.Font.supportingText)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help(localized("helper.help"))
                    .accessibilityLabel(localized("About this setting"))
                    .accessibilityIdentifier("WakecupHelperInfo")
                    .popover(isPresented: $showingHint) {
                        Text(localized("helper.help")).font(Font(AppStyle.Font.supportingText))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(MenuLayout.tooltipPadding).frame(width: MenuLayout.tooltipWidth, alignment: .leading)
                    }
            }
        } detail: {
            Text(localized(presentation.statusKey))
                .foregroundStyle(presentation.needsAttention ? Color.orange : Color.secondary)
                .lineLimit(1)
        } action: {
            actionButton
        }
            .padding(.horizontal, MenuLayout.inset)
            .frame(height: MenuLayout.helperRowHeight)
            .help(localized(presentation.descriptionKey))
            .accessibilityElement(children: .contain)
            .accessibilityHint(localized(presentation.descriptionKey))
    }

    private var actionButton: some View {
        Button(localized(presentation.action.titleKey), action: action)
            .disabled(!actionEnabled)
            .accessibilityIdentifier("WakecupHelperAction")
            .accessibilityLabel(localized(presentation.action.accessibilityKey))
    }
}
