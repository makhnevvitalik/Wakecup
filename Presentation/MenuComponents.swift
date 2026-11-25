import AppKit
import SwiftUI

struct MenuCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: AppStyle.Color.cardBackground),
                in: RoundedRectangle(cornerRadius: AppStyle.Layout.cardCornerRadius))
    }
}

struct MenuSectionHeading: NSViewRepresentable {
    let title: String
    let symbol: String

    func makeNSView(context: Context) -> NSStackView {
        let icon = NSImageView()
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.alignment = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: MenuLayout.iconSize),
            icon.heightAnchor.constraint(equalToConstant: MenuLayout.iconSize)
        ])
        let label = NSTextField(labelWithString: title)
        label.font = AppStyle.Font.sectionTitle
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        let stack = NSStackView(views: [icon, label])
        stack.identifier = NSUserInterfaceItemIdentifier("WakecupSectionHeading")
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = MenuLayout.headingSpacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: AppStyle.Layout.cardInset, bottom: 0, right: AppStyle.Layout.cardInset)
        updateNSView(stack, context: context)
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        guard let icon = stack.arrangedSubviews.first as? NSImageView,
              let label = stack.arrangedSubviews.last as? NSTextField else { return }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(AppStyle.Icon.sectionSymbolConfiguration)
        label.stringValue = title
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSStackView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.fittingSize.width
        return CGSize(width: width, height: AppStyle.Layout.sectionHeaderHeight)
    }
}

struct CompactCommandButton: NSViewRepresentable {
    let title: String
    let accessibilityTitle: String
    var value: String? = nil
    var help: String? = nil
    var identifier: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
        AppStyle.configureCompactButton(button)
        button.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled && context.environment.isEnabled
        button.toolTip = help
        button.setAccessibilityLabel(accessibilityTitle)
        button.setAccessibilityValue(value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func press() { action?() }
    }
}

struct MenuDetailRow<Heading: View, Detail: View, Action: View>: View {
    @ViewBuilder var heading: Heading
    @ViewBuilder var detail: Detail
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: AppStyle.Layout.rowItemSpacing) {
            VStack(alignment: .leading, spacing: MenuLayout.detailSpacing) {
                heading.font(Font(AppStyle.Font.body))
                detail.font(Font(AppStyle.Font.supportingText)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            action
        }.frame(minHeight: AppStyle.Layout.rowHeight)
    }
}

struct MenuToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: (text: String, accessibilityLabel: String, identifier: String)? = nil
    var body: some View {
        HStack(spacing: AppStyle.Layout.rowItemSpacing) {
            HStack(spacing: AppStyle.Layout.rowItemSpacing) {
                Text(title).font(Font(AppStyle.Font.body))
                if let help {
                    MenuInfoButton(text: help.text, accessibilityTitle: help.accessibilityLabel, identifier: help.identifier)
                }
            }
            Spacer(minLength: 10)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                .frame(height: MenuLayout.compactControlHeight)
                .accessibilityHint(help?.text ?? "")
        }.padding(.horizontal, AppStyle.Layout.cardInset).frame(height: AppStyle.Layout.rowHeight)
    }
}

struct MenuInfoButton: View {
    let text: String
    let accessibilityTitle: String
    let identifier: String
    @State private var showingHint = false

    var body: some View {
        Button { showingHint.toggle() } label: {
            Image(systemName: "info.circle")
                .font(Font(AppStyle.Font.supportingText))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $showingHint) { MenuFeedbackPopover(text: text) }
    }
}

// Feedback can contain long system errors. Keep short details natural-sized,
// but allow long details to scroll instead of growing the panel or clipping.
struct MenuFeedbackPopover: View {
    let text: String
    private var message: some View {
        Text(text).font(Font(AppStyle.Font.supportingText))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(MenuLayout.tooltipPadding)
    }
    var body: some View {
        ViewThatFits(in: .vertical) {
            message
            ScrollView { message }.frame(height: MenuLayout.tooltipMaximumHeight)
        }.frame(width: MenuLayout.tooltipWidth).frame(maxHeight: MenuLayout.tooltipMaximumHeight)
    }
}
