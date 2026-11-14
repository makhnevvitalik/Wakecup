import AppKit
import SwiftUI

struct SessionActionsView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        primaryButton
        .controlSize(.large)
        .frame(minHeight: MenuLayout.primaryActionHeight)
        .disabled(model.isRestarting || model.startPowerRestriction != nil || model.helper.working || model.phase.showsProgress || (model.needsRecovery && model.busy)
            || (!model.busy && !model.needsRecovery && (model.display.transitioning || !model.durationInputIsValid
                || (model.closedLid && model.helper.selected && model.helper.checking))))
    }

    @ViewBuilder private var primaryButton: some View {
        if model.phase == .active && model.hasSettingsDraft {
            actionButton.buttonStyle(.bordered)
        } else {
            actionButton.buttonStyle(.borderedProminent)
        }
    }

    private var actionButton: some View {
        Button(action: performPrimaryAction) {
            Text(actionTitle)
                .font(Font(AppStyle.Font.primaryAction))
                .frame(maxWidth: .infinity)
        }
    }

    private var actionTitle: String {
        if model.needsRecovery { return localized("Restore Normal Sleep") }
        if model.isRestarting || model.phase == .active || model.phase == .stopping { return localized("Stop") }
        return localized("Start")
    }

    private func performPrimaryAction() {
        AppStyle.commitActiveFieldEditor(in: NSApp.keyWindow)
        if model.needsRecovery { model.recover() }
        else if model.busy { model.stop() }
        else { model.start() }
    }
}

struct SessionSettingsFooter: View {
    @ObservedObject var model: SessionModel
    let showHelp: () -> Void
    @ObservedObject private var localization = AppLocalization.shared

    private enum FeedbackStyle {
        case notice, progress, error, backlightCountdown
    }

    private struct Feedback {
        let text: String
        let style: FeedbackStyle

        init(_ text: String, _ style: FeedbackStyle = .notice) {
            self.text = text
            self.style = style
        }
    }

    private var feedback: Feedback? {
        if model.waitingForPassword {
            return Feedback(localized("Confirm the macOS prompt"))
        }
        if let error = model.displayControlError, model.isBacklightOff {
            return Feedback(error.text(using: localized), .error)
        }
        if model.isRestarting || (model.settingsApplying && model.phase == .active) {
            return Feedback(localized("Applying settings…"), .progress)
        }
        if model.needsRecovery, !model.busy, let message = model.message {
            return Feedback(message.text(using: localized), .error)
        }
        if let restriction = model.startPowerRestriction {
            return Feedback(powerNotice(restriction))
        }
        if let error = model.settingsMessage {
            return Feedback(error.text(using: localized), .error)
        }
        if let seconds = model.backlightCountdown {
            return Feedback(localizedFormat("Backlight turns off in %ld s", seconds), .backlightCountdown)
        }
        if model.phase == .authorizing {
            return Feedback(localized(model.needsRecovery ? "Restoring normal sleep…" : "Starting session"), .progress)
        }
        if model.phase == .stopping {
            return Feedback(localized("Stopping…"), .progress)
        }
        if let error = model.displayControlError {
            return Feedback(error.text(using: localized), .error)
        }
        if model.phase != .active, let message = model.message {
            let style: FeedbackStyle = model.phase == .failed ? .error : .notice
            return Feedback(message.text(using: localized), style)
        }
        return nil
    }

    private func powerNotice(_ restriction: PowerRestriction) -> String {
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

    var preferredHeight: CGFloat {
        let feedbackHeight = feedback == nil ? 0 : MenuLayout.feedbackRowHeight
        let actionsHeight = model.showsSettingsActions ? MenuLayout.settingsActionsHeight : 0
        let cardHeight = feedbackHeight + actionsHeight
        let helpHeight = MenuLayout.helpLinkHeight + AppStyle.Layout.panelInset
        return cardHeight == 0 ? helpHeight : helpHeight + AppStyle.Layout.cardSpacing + cardHeight
    }

    var body: some View {
        let notice = feedback
        VStack(spacing: AppStyle.Layout.cardSpacing) {
            if notice != nil || model.showsSettingsActions {
                MenuCard {
                    if let notice { feedbackRow(notice) }
                    if model.showsSettingsActions { actions.modifier(SettingsActionsFade()) }
                }
            }
            Button(action: showHelp) {
                Label(localized("Mac won’t sleep with Wakecup off?"), systemImage: "questionmark.circle")
                    .font(Font(AppStyle.Font.emphasizedBody))
                    .frame(maxWidth: .infinity, minHeight: MenuLayout.helpLinkHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.link)
            .padding(.horizontal, AppStyle.Layout.cardInset)
        }
        .tint(Color(AppStyle.Color.accent))
        .padding([.horizontal, .bottom], AppStyle.Layout.panelInset)
    }

    private func feedbackRow(_ feedback: Feedback) -> some View {
        HStack(spacing: MenuLayout.headingSpacing) {
            feedbackLabel(feedback)
            if feedback.style == .backlightCountdown {
                Spacer(minLength: 0)
                Button(localized("Cancel backlight countdown"), action: model.cancelBacklightCountdown)
                    .buttonStyle(.link)
                    .font(Font(AppStyle.Font.controlLabel))
                    .accessibilityIdentifier("WakecupCancelBacklightCountdown")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MenuLayout.feedbackRowHeight)
        .padding(.horizontal, AppStyle.Layout.cardInset)
    }

    private func feedbackLabel(_ feedback: Feedback) -> some View {
        HStack(spacing: MenuLayout.headingSpacing) {
            switch feedback.style {
            case .progress:
                ProgressView().controlSize(.small).accessibilityHidden(true)
            case .error:
                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
            case .notice, .backlightCountdown:
                EmptyView()
            }
            Text(feedback.text).lineLimit(2)
        }
        .font(Font(AppStyle.Font.supportingText))
        .foregroundStyle(feedback.style == .error ? Color.red : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("WakecupSessionNotice")
        .help(feedback.text)
    }

    private var actions: some View {
        HStack(spacing: AppStyle.Layout.cardSpacing) {
            Button(localized("Cancel edits")) {
                AppStyle.commitActiveFieldEditor(in: NSApp.keyWindow)
                model.discardSettingsDraft()
            }
            .buttonStyle(.bordered)
            .tint(Color(nsColor: .systemRed))
            .disabled(!model.canEditSettingsDraft)
            .accessibilityIdentifier("WakecupCancelSettings")

            Button(localized("Apply")) {
                AppStyle.commitActiveFieldEditor(in: NSApp.keyWindow)
                model.applySettingsDraft()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApplySettingsDraft)
            .accessibilityIdentifier("WakecupApplySettings")
        }
        .font(Font(AppStyle.Font.controlLabel))
        .controlSize(.regular)
        .padding(.horizontal, AppStyle.Layout.cardInset)
        .frame(maxWidth: .infinity)
        .frame(height: MenuLayout.settingsActionsHeight)
    }
}

private struct SettingsActionsFade: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : .easeOut(duration: MenuLayout.settingsActionsFadeDuration)) {
                $0.opacity(reduceMotion || isVisible ? 1 : 0)
            }
            .onAppear { isVisible = true }
    }
}
