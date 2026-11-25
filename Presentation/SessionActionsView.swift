import AppKit
import SwiftUI

struct SessionActionsView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        controls
            // Keep the native button chrome while letting the custom label set the height.
            .controlSize(.mini)
            .buttonBorderShape(.capsule)
            .frame(height: AppStyle.Layout.sessionActionAreaHeight)
    }

    @ViewBuilder private var controls: some View {
        if model.isReturningControl || model.needsBrightnessRecovery || model.needsRecovery {
            primaryButton.prominentSessionAction()
        } else if model.showsSettingsActions {
            HStack(spacing: AppStyle.Layout.cardSpacing) {
                button(localized("Cancel edits")) {
                    AppStyle.commitActiveFieldEditor(in: NSApp.keyWindow)
                    model.discardSettingsDraft()
                }
                .neutralSessionAction()
                .disabled(!model.canEditSettingsDraft)
                .accessibilityIdentifier("WakecupCancelSettings")

                button(localized("Apply")) {
                    AppStyle.commitActiveFieldEditor(in: NSApp.keyWindow)
                    model.applySettingsDraft()
                }
                .prominentSessionAction()
                .disabled(!model.canApplySettingsDraft)
                .accessibilityIdentifier("WakecupApplySettings")
            }
        } else if let seconds = model.backlightCountdown {
            countdownButton(seconds)
        } else if model.phase == .active {
            primaryButton
                .neutralSessionAction()
        } else {
            primaryButton.prominentSessionAction()
        }
    }

    private var primaryButton: some View {
        let helper = model.helperStatus
        return button(actionTitle, action: performPrimaryAction)
            .disabled(model.isRestarting || helper.working || model.statusPhase.showsProgress
                || (model.needsRecovery && model.busy)
                || (!model.busy && !model.needsRecovery && !model.needsBrightnessRecovery
                    && (model.startPowerRestriction != nil || model.isDisplayTransitioning || !model.durationInputIsValid
                    || (model.closedLid && helper.selected && helper.checking))))
        .accessibilityIdentifier("WakecupPrimaryAction")
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel {
                Text(title).font(Font(AppStyle.Font.primaryAction))
            }
        }
    }

    private func countdownButton(_ seconds: Int) -> some View {
        let remaining = localizedFormat("%ld s", seconds)
        let message = localizedFormat("Backlight turns off in %@", remaining)
        var caption = AttributedString(message)
        if let range = caption.range(of: remaining) {
            caption[range].inlinePresentationIntent = .stronglyEmphasized
        }

        return Button {
            model.cancelBacklightCountdown()
        } label: {
            actionLabel {
                VStack(spacing: AppStyle.Layout.sessionCountdownLineSpacing) {
                    Text(localized("Cancel backlight countdown")).font(Font(AppStyle.Font.primaryAction))
                    Text(caption)
                        .font(Font(AppStyle.Font.supportingText))
                        .monospacedDigit()
                }
            }
        }
        .neutralSessionAction()
        .accessibilityLabel(localized("Cancel turning off the backlight"))
        .accessibilityValue(message)
        .accessibilityIdentifier("WakecupCancelBacklightCountdown")
    }

    private func actionLabel(@ViewBuilder content: () -> some View) -> some View {
        content()
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: AppStyle.Layout.sessionActionLabelHeight)
    }

    var actionTitle: String {
        if model.isReturningControl && !model.phase.isBusy && model.isBacklightOff {
            return localized("Restoring brightness…")
        }
        if model.needsBrightnessRecovery { return localized("Restore brightness") }
        if model.needsRecovery { return localized("Restore Normal Sleep") }
        if model.isRestarting || model.phase == .active || model.statusPhase == .stopping { return localized("Stop") }
        return localized("Start")
    }

    private func performPrimaryAction() {
        AppStyle.commitActiveFieldEditor(in: NSApp.keyWindow)
        if model.needsBrightnessRecovery { model.restoreBrightness() }
        else if model.needsRecovery { model.recover() }
        else if model.busy {
            if !model.showsSettingsActions && model.backlightCountdown == nil { model.stop() }
        } else { model.start() }
    }
}

private extension View {
    func prominentSessionAction() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color(nsColor: AppStyle.Color.prominentAction))
    }

    func neutralSessionAction() -> some View {
        buttonStyle(.bordered)
            .tint(Color(nsColor: AppStyle.Color.neutralAction))
            .overlay {
                Capsule(style: .circular)
                    .strokeBorder(Color(nsColor: AppStyle.Color.neutralActionBorder), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

struct SessionSettingsFooter: View {
    let showHelp: () -> Void
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        Button(action: showHelp) {
            Text(localized("Mac won’t sleep with Wakecup off?"))
                .font(Font(AppStyle.Font.emphasizedBody))
                .frame(maxWidth: .infinity, minHeight: MenuLayout.helpLinkHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.link)
        .padding(.horizontal, AppStyle.Layout.cardInset + AppStyle.Layout.panelInset)
        .padding(.bottom, AppStyle.Layout.panelInset)
    }
}

struct SessionFeedback: Equatable {
    enum Style { case notice, progress, error }
    enum Placement { case primaryAction, footer }

    let text: String
    let style: Style
    let placement: Placement

    init(_ text: String, _ style: Style = .notice, placement: Placement = .footer) {
        self.text = text
        self.style = style
        self.placement = placement
    }

    static func current(for model: SessionModel, placement: Placement) -> Self? {
        switch placement {
        case .primaryAction: actionFeedback(for: model)
        case .footer: operationFeedback(for: model)
        }
    }

    private static func actionFeedback(for model: SessionModel) -> Self? {
        if model.waitingForPassword {
            return SessionFeedback(localized("Confirm the macOS prompt"), placement: .primaryAction)
        }
        if model.needsBrightnessRecovery {
            let error = model.displayControlError?.text(using: localized) ?? localized("Could not restore brightness.")
            let shortcutHint = model.displayShortcut.map { localizedFormat("Press %@ to restore brightness.", $0.displayName) }
            return SessionFeedback([error, shortcutHint].compactMap { $0 }.joined(separator: " "), .error, placement: .primaryAction)
        }
        if let error = model.displayControlError, model.isBacklightOff, !model.isReturningControl {
            return SessionFeedback(error.text(using: localized), .error, placement: .primaryAction)
        }
        if model.needsRecovery, !model.recoveryInProgress, let message = model.message {
            return sessionMessage(message, for: model, placement: .primaryAction)
        }
        if let restriction = model.startPowerRestriction {
            return SessionFeedback(powerNotice(restriction), placement: .primaryAction)
        }
        if let error = model.settingsMessage, !model.settingsApplying {
            return SessionFeedback(error.text(using: localized), .error, placement: .primaryAction)
        }
        return nil
    }

    private static func operationFeedback(for model: SessionModel) -> Self? {
        if model.isReturningControl {
            return SessionFeedback(SessionModel.returningControlMessage.text(using: localized), .progress)
        }
        // The authorization notice already explains this operation above the settings.
        if model.waitingForPassword { return nil }
        if model.isRestarting || (model.settingsApplying && model.phase == .active) {
            return SessionFeedback(localized("Applying settings…"), .progress)
        }
        if model.recoveryInProgress {
            return SessionFeedback(localized("Restoring normal sleep…"), .progress)
        }
        if !model.needsRecovery, let message = model.priorityStopMessage,
           !model.isBacklightOff || model.displayControlError == nil {
            return sessionMessage(message, for: model, placement: .footer)
        }
        if model.phase == .authorizing {
            return SessionFeedback(localized("Starting session"), .progress)
        }
        if let error = model.displayControlError, !model.isBacklightOff, model.settingsMessage == nil {
            return SessionFeedback(error.text(using: localized), .error)
        }
        if !model.needsRecovery, model.phase != .active, let message = model.message {
            return sessionMessage(message, for: model, placement: .footer)
        }
        return nil
    }

    private static func sessionMessage(_ message: SessionMessage, for model: SessionModel, placement: Placement) -> Self {
        SessionFeedback(message.text(using: localized), model.phase == .failed ? .error : .notice, placement: placement)
    }

    private static func powerNotice(_ restriction: PowerRestriction) -> String {
        switch restriction {
        case .chargerRequired:
            localized("Connect power or enable Keep awake on battery.")
        case .lowCharge(let threshold):
            localizedFormat("Connect power or lower the %d%% battery limit.", threshold)
        case .powerUnavailable, .chargeUnavailable:
            localized("Wait for the power status to become available, or connect power.")
        case .invalidThreshold:
            localized("Choose a battery stop threshold between 10% and 90%.")
        }
    }

    var topInset: CGFloat { placement == .footer ? AppStyle.Layout.cardSpacing : 0 }
    var height: CGFloat { topInset + rowHeight + AppStyle.Layout.cardSpacing }

    var rowHeight: CGFloat { min(naturalRowHeight, MenuLayout.maximumFeedbackHeight) }

    var naturalRowHeight: CGFloat {
        guard style != .progress else { return MenuLayout.feedbackRowHeight }
        let iconWidth = style == .error ? MenuLayout.iconSize + MenuLayout.headingSpacing : 0
        let width = MenuLayout.width - 2 * (AppStyle.Layout.panelInset + AppStyle.Layout.cardInset) - iconWidth
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: AppStyle.Font.supportingText]
        )
        return max(MenuLayout.feedbackRowHeight, ceil(bounds.height) + 8)
    }

}

struct SessionFeedbackView: View {
    let feedback: SessionFeedback?
    var outgoing = false

    var body: some View {
        if let feedback {
            MenuCard {
                feedbackRow(feedback)
            }
            .padding(.horizontal, AppStyle.Layout.panelInset)
            .padding(.top, feedback.topInset)
            .padding(.bottom, AppStyle.Layout.cardSpacing)
            .allowsHitTesting(!outgoing)
            .accessibilityHidden(outgoing)
        }
    }

    private func feedbackRow(_ feedback: SessionFeedback) -> some View {
        HStack(spacing: MenuLayout.headingSpacing) {
            if feedback.naturalRowHeight > MenuLayout.maximumFeedbackHeight {
                ScrollView {
                    feedbackLabel(feedback)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            } else {
                feedbackLabel(feedback)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: feedback.rowHeight)
        .padding(.horizontal, AppStyle.Layout.cardInset)
    }

    private func feedbackLabel(_ feedback: SessionFeedback) -> some View {
        HStack(spacing: MenuLayout.headingSpacing) {
            switch feedback.style {
            case .progress:
                ProgressView().controlSize(.small).accessibilityHidden(true)
            case .error:
                Image(systemName: "exclamationmark.circle")
                    .frame(width: MenuLayout.iconSize)
                    .accessibilityHidden(true)
            case .notice:
                EmptyView()
            }
            if feedback.style == .error || feedback.style == .notice {
                Text(feedback.text).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(feedback.text).lineLimit(2)
            }
        }
        .font(Font(AppStyle.Font.supportingText))
        .foregroundStyle(feedback.style == .error ? Color.red : Color(nsColor: AppStyle.Color.stateDetailText))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("WakecupSessionNotice")
        .help(feedback.text)
    }

}
