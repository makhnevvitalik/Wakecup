import Foundation

/// Both command-line clients use the application model that owns the current session.
final class AutomationController {
    private static let mcpKey = "mcpEnabled"
    private static let mcpSessionKey = "mcpSession"
    private unowned let model: SessionModel
    private let defaults: UserDefaults
    private var mcpSession: UUID?

    init(model: SessionModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        guard defaults.bool(forKey: Self.mcpKey) else { return }
        if let stored = defaults.string(forKey: Self.mcpSessionKey), let session = UUID(uuidString: stored) {
            mcpSession = session
        } else {
            // Older builds persisted only the enabled setting.
            let session = UUID()
            defaults.set(session.uuidString, forKey: Self.mcpSessionKey)
            mcpSession = session
        }
    }

    var mcpEnabled: Bool {
        get { mcpSession != nil }
        set {
            guard newValue != mcpEnabled else { return }
            if newValue {
                let session = UUID()
                defaults.set(session.uuidString, forKey: Self.mcpSessionKey)
                defaults.set(true, forKey: Self.mcpKey)
                mcpSession = session
            } else {
                defaults.set(false, forKey: Self.mcpKey)
                defaults.removeObject(forKey: Self.mcpSessionKey)
                mcpSession = nil
            }
        }
    }

    func receive(_ envelope: AutomationEnvelope) -> AutomationReply {
        guard envelope.viaMCP else { return execute(envelope.request) }
        guard let mcpSession else {
            return AutomationReply(outcome: .rejected, message: "Enable MCP in the Wakecup settings menu.")
        }
        if envelope.mcpSession == nil && envelope.request.action == .status {
            return AutomationReply(outcome: .completed, mcpSession: mcpSession)
        }
        guard envelope.mcpSession == mcpSession else {
            return AutomationReply(outcome: .rejected, message: "Reconnect the Wakecup MCP server.")
        }
        return execute(envelope.request)
    }

    private func execute(_ request: AutomationRequest) -> AutomationReply {
        do {
            let result = try perform(request)
            let outcome: AutomationReply.Outcome
            let message: String?
            switch result {
            case .completed: (outcome, message) = (.completed, nil)
            case .pending(let notice): (outcome, message) = (.pending, text(notice))
            case .rejected(let issue): (outcome, message) = (.rejected, text(issue))
            case .partiallyApplied(let issue): (outcome, message) = (.partiallyApplied, partialMessage(issue))
            }
            return AutomationReply(outcome: outcome, message: message, status: status())
        } catch {
            return AutomationReply(outcome: .rejected, message: error.localizedDescription, status: status())
        }
    }

    private func perform(_ request: AutomationRequest) throws -> SessionOperationResult {
        switch request.action {
        case .status, .helperStatus:
            return .completed
        case .start, .configure, .adjust:
            let end = try endTime(for: request)
            return try model.applySettings(endTime: end, closedLid: request.closedLid, allowBattery: request.allowBattery,
                threshold: request.threshold, displayMode: request.display, starting: request.action == .start)
        case .stop:
            return model.stop()
        case .restoreBrightness:
            return model.display.restoreForUser(running: model.phase == .active)
        case .cancelBlackout:
            return model.display.cancelBlackout()
        case .setShortcut:
            guard let shortcut = request.shortcut else { throw WakecupError(message: "A restore shortcut is required.") }
            return try model.setDisplayShortcut(shortcut)
        case .clearShortcut:
            return try model.setDisplayShortcut(nil)
        case .helperUse:
            guard let enabled = request.useHelper, model.canSelectHelperMode, !enabled || model.helper.state == .ready else {
                throw WakecupError(message: "The requested helper mode is unavailable.")
            }
            model.helper.select(enabled)
            return .completed
        case .helperInstall, .helperUpdate, .helperRemove:
            guard model.canChangeHelper else { throw WakecupError(message: "Stop Wakecup and restore sleep before changing the helper.") }
            guard model.helper.installed == (request.action != .helperInstall) else {
                throw WakecupError(message: model.helper.installed ? "The helper is already installed. Use update." : "The helper is not installed.")
            }
            return model.helper.requestInstallation(remove: request.action == .helperRemove)
        case .restoreSleep:
            return model.recover()
        }
    }

    private func endTime(for request: AutomationRequest) throws -> EndTimeSelection.Choice? {
        if request.action == .adjust {
            guard model.phase == .active, let end = model.endDate, let seconds = request.seconds else {
                throw WakecupError(message: "An active timer with a deadline and an adjustment are required.")
            }
            guard seconds.magnitude >= UInt(EndTimeSelection.minimumDurationSeconds) else {
                throw WakecupError(message: "Adjust the timer by at least \(EndTimeSelection.minimumDurationSeconds) seconds.")
            }
            return .date(end.addingTimeInterval(Double(seconds)))
        }
        let specified = [request.seconds != nil, request.until != nil, request.indefinite == true].filter { $0 }.count
        guard specified <= 1, specified == 1 || request.action != .start else {
            throw WakecupError(message: "Choose one of duration, end time, or indefinitely.")
        }
        if let seconds = request.seconds {
            try EndTimeSelection.validateDuration(seconds)
            return .duration(seconds: seconds)
        }
        if let date = request.until { return .date(date) }
        return request.indefinite == true ? .preset(.indefinitely, date: nil) : nil
    }

    private func partialMessage(_ issue: SessionMessage) -> String {
        issue.text(using: { $0 }) + (model.phase == .active ? " Retry only the display change." : "")
    }

    private func status() -> AutomationStatus {
        AutomationStatus(phase: model.isRestarting ? "restarting" : model.phase.rawValue,
            endTime: model.endDate, remainingSeconds: model.remaining, closedLid: model.closedLid,
            allowBattery: model.allowBattery, threshold: Int(model.threshold), batteryPercent: model.power?.percent,
            onAC: model.power?.onAC, display: model.displayMode, shortcut: model.displayShortcut,
            backlightOff: model.isBacklightOff, blackoutCountdown: model.backlightCountdown,
            helperState: model.helper.state.rawValue, helperSelected: model.helper.selected,
            helperWorking: model.helper.working, helperChecking: model.helper.checking, helperDetail: model.helper.detail,
            helperInstallationError: model.helper.installationError, needsRecovery: model.needsRecovery, mcpEnabled: mcpEnabled,
            settingsApplying: model.settingsApplying, displayTransitioning: model.display.transitioning,
            settingsPartiallyApplied: model.partialSettingsIssue != nil,
            message: model.partialSettingsIssue.map(partialMessage) ?? text(model.settingsMessage ?? model.displayControlError ?? model.message))
    }

    private func text(_ message: SessionMessage?) -> String? { message?.text(using: { $0 }) }
}
