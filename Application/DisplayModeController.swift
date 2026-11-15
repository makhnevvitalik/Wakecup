import Combine
import Foundation

// Display state has its own transaction/lifetime; the sleep timer only reports
// when it starts/stops. No privileged guardian configuration is changed here.
final class DisplayModeController: ObservableObject {
    enum BacklightState { case monitoring, brightnessReturned, restorerStopped }
    enum RestorationPolicy { case saved, preserveVisible, visibleOnly }

    struct Operations {
        let assertions: (Bool) throws -> Void
        let enter: (DisplayShortcut, @escaping () -> Void, @escaping (Result<Void, Error>, Bool) -> Void) -> Void
        let restore: (RestorationPolicy, @escaping (Result<Bool, Error>) -> Void) -> Void
        let validate: (DisplayShortcut) throws -> Void
        let checkBacklight: (@escaping (BacklightState) -> Void) -> Void
    }
    private enum Transition { case entering, restoring }
    private enum BlackoutCountdown { case running(until: TimeInterval), paused }
    private static let blackoutDelay: TimeInterval = 10

    @Published private(set) var mode: DisplayMode
    @Published private(set) var shortcut: DisplayShortcut?
    @Published private(set) var isBacklightOff = false
    @Published private(set) var error: SessionMessage?
    @Published private var transition: Transition?
    @Published private var countdown: BlackoutCountdown?
    var transitioning: Bool { transition != nil }
    var hasCountdown: Bool { countdown != nil }

    private let defaults: UserDefaults
    private let operations: Operations
    private var activationID: UUID?
    private var previousMode: DisplayMode
    private var restoreAfterEntry: RestorationPolicy?
    private var blackoutSessionEnded = false
    private var restorationWaiters: [() -> Void] = []
    private var checkingBacklight = false
    private var reportedHealthFailure = false

    init(defaults: UserDefaults, operations: Operations) {
        self.defaults = defaults; self.operations = operations
        if let data = defaults.data(forKey: "displayRestoreShortcut") {
            if let value = try? JSONDecoder().decode(DisplayShortcut.self, from: data), value.isValid {
                shortcut = value
            } else { defaults.removeObject(forKey: "displayRestoreShortcut") }
        }
        mode = defaults.string(forKey: "displayMode").flatMap(DisplayMode.init(rawValue:))
            ?? .mayTurnOff
        let savedPreviousMode = defaults.string(forKey: "displayModeBeforeBlackout").flatMap(DisplayMode.init(rawValue:))
        previousMode = savedPreviousMode == .mayTurnOff ? .mayTurnOff : .keepOn
        if mode == .backlightOff && shortcut == nil { mode = previousMode; save() }
    }

    func clearError() { error = nil }

    func validateShortcut(_ value: DisplayShortcut) throws {
        guard value.isValid else { throw WakecupError(message: "display.shortcut.invalid") }
        try operations.validate(value)
    }

    func setShortcut(_ value: DisplayShortcut?, running: Bool) throws -> SessionOperationResult {
        guard !isBacklightOff, !transitioning else { throw WakecupError(message: "display.shortcut.locked") }
        if let value { try validateShortcut(value) }
        shortcut = value
        error = nil
        if let value { defaults.set(try JSONEncoder().encode(value), forKey: "displayRestoreShortcut") }
        else {
            defaults.removeObject(forKey: "displayRestoreShortcut")
            if mode == .backlightOff {
                cancelCountdown()
                return returnToMode(previousMode, running: running)
            }
        }
        return .completed
    }

    @discardableResult
    func setMode(_ value: DisplayMode, running: Bool, now: TimeInterval, assertionsAlreadyApplied: Bool = false,
                 completion: ((SessionOperationResult) -> Void)? = nil) -> SessionOperationResult {
        guard value != mode else { return .completed }
        guard !transitioning else { return .rejected("Wait for the display change to finish.") }
        guard value != .backlightOff || shortcut != nil else {
            return reportFailure("Choose a restore shortcut before turning the backlight off.")
        }
        if isBacklightOff {
            return restoreBrightness(to: value, running: running, policy: .preserveVisible, completion: completion)
        }
        if running && !assertionsAlreadyApplied {
            do { try operations.assertions(value.keepsDisplayOn) }
            catch { return reportFailure(Self.assertionFailure) }
        }
        cancelCountdown()
        if value == .backlightOff {
            previousMode = mode
            defaults.set(previousMode.rawValue, forKey: "displayModeBeforeBlackout")
        }
        mode = value
        error = nil
        save()
        if running { activateIfConfigured(at: now) }
        return .completed
    }

    private static let assertionFailure: SessionMessage = "Could not change the display setting. Try again."

    private func reportFailure(_ message: SessionMessage) -> SessionOperationResult {
        error = message
        return .rejected(message)
    }

    func activateIfConfigured(at now: TimeInterval) {
        guard mode == .backlightOff, !isBacklightOff, !transitioning else { return }
        countdown = .running(until: now + Self.blackoutDelay)
    }

    func countdownSeconds(at now: TimeInterval) -> Int? {
        guard case let .running(deadline) = countdown else { return nil }
        return max(1, Int(ceil(deadline - now)))
    }

    func pauseCountdown() {
        if case .running = countdown { countdown = .paused }
    }

    func resumeCountdown(at now: TimeInterval) {
        guard case .paused = countdown else { return }
        countdown = .running(until: now + Self.blackoutDelay)
    }

    func cancelCountdown() {
        if countdown != nil { countdown = nil }
    }

    @discardableResult
    func cancelBlackout() -> SessionOperationResult {
        guard hasCountdown else { return .completed }
        cancelCountdown()
        return returnToMode(previousMode, running: true)
    }

    func advanceCountdown(at now: TimeInterval) {
        guard case let .running(deadline) = countdown, now >= deadline else { return }
        cancelCountdown()
        darken()
    }

    private func darken() {
        guard let shortcut else {
            error = "Choose a restore shortcut before turning the backlight off."
            return
        }
        let token = UUID()
        activationID = token
        blackoutSessionEnded = false
        reportedHealthFailure = false
        transition = .entering
        operations.enter(shortcut, { [weak self] in
            guard let self, self.activationID == token else { return }
            self.restoreForUser(running: !self.blackoutSessionEnded)
        }, { [weak self] result, needsRestoration in
            guard let self else { return }
            self.transition = nil
            self.isBacklightOff = needsRestoration
            let restore = self.restoreAfterEntry
            self.restoreAfterEntry = nil
            self.error = nil
            if !needsRestoration {
                self.activationID = nil
                self.returnToMode(self.previousMode, running: !self.blackoutSessionEnded)
            }
            if case .failure(let failure) = result {
                self.error = SessionMessage(failure.localizedDescription)
            }
            if let restore {
                if needsRestoration {
                    self.restoreBrightness(to: self.previousMode, running: !self.blackoutSessionEnded, policy: restore)
                } else { self.flushRestorationWaiters() }
            }
        })
    }

    @discardableResult
    private func returnToMode(_ value: DisplayMode, running: Bool) -> SessionOperationResult {
        mode = value
        save()
        if running {
            do { try operations.assertions(value.keepsDisplayOn) }
            catch { return reportFailure(Self.assertionFailure) }
        }
        return .completed
    }

    @discardableResult
    private func restoreBrightness(to value: DisplayMode, running: Bool, policy: RestorationPolicy,
                                   notice: SessionMessage? = nil,
                                   completion: ((SessionOperationResult) -> Void)? = nil) -> SessionOperationResult {
        transition = .restoring
        var outcome = SessionOperationResult.pending()
        operations.restore(policy) { [weak self] result in
            guard let self else { return }
            self.transition = nil
            switch result {
            case .success(true):
                self.isBacklightOff = false
                self.activationID = nil
                self.error = notice
                // A stop during restoration must not recreate display assertions.
                let ended = self.blackoutSessionEnded
                outcome = self.returnToMode(running && ended ? self.previousMode : value, running: running && !ended)
            case .success(false):
                // The display went dark again before the worker could confirm the observed brightness.
                if self.blackoutSessionEnded {
                    self.restoreBrightness(to: self.previousMode, running: false, policy: .preserveVisible)
                    return
                }
                outcome = .completed
            case .failure(let failure):
                outcome = self.reportFailure(SessionMessage(failure.localizedDescription))
            }
            completion?(outcome)
            self.flushRestorationWaiters()
        }
        return outcome
    }

    @discardableResult
    func restoreForUser(running: Bool) -> SessionOperationResult {
        if hasCountdown { return cancelBlackout() }
        if transition == .entering {
            restoreAfterEntry = restoreAfterEntry ?? .saved
            return .pending()
        }
        if transition == .restoring { return .pending() }
        guard isBacklightOff else { return .completed }
        error = nil
        return restoreBrightness(to: previousMode, running: running, policy: .saved)
    }

    @discardableResult
    func finish(completion: (() -> Void)? = nil) -> SessionOperationResult {
        cancelCountdown()
        blackoutSessionEnded = true
        if let completion { restorationWaiters.append(completion) }
        if transition == .entering {
            restoreAfterEntry = restoreAfterEntry ?? .preserveVisible
            return .pending()
        }
        if transition == .restoring { return .pending() }
        if isBacklightOff { return restoreBrightness(to: previousMode, running: false, policy: .preserveVisible) }
        flushRestorationWaiters()
        return .completed
    }

    private func flushRestorationWaiters() {
        let waiters = restorationWaiters
        restorationWaiters.removeAll()
        waiters.forEach { $0() }
    }

    func checkBacklight() {
        guard isBacklightOff, !transitioning, !checkingBacklight, let token = activationID else { return }
        checkingBacklight = true
        operations.checkBacklight { [weak self] state in
            guard let self else { return }
            self.checkingBacklight = false
            guard self.activationID == token, !self.transitioning else { return }
            switch state {
            case .monitoring:
                break
            case .brightnessReturned:
                self.restoreBrightness(to: self.previousMode, running: !self.blackoutSessionEnded, policy: .visibleOnly)
            case .restorerStopped:
                guard !self.reportedHealthFailure else { return }
                self.reportedHealthFailure = true
                self.restoreBrightness(to: self.previousMode, running: !self.blackoutSessionEnded,
                                       policy: .preserveVisible, notice: "The brightness safety process stopped. Check the display setting.")
            }
        }
    }

    private func save() {
        defaults.set(mode.rawValue, forKey: "displayMode")
    }
}
