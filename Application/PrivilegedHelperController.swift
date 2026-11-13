import Combine
import Foundation

final class PrivilegedHelperController: ObservableObject {
    enum State: String { case missing, ready, updateRequired, unavailable }
    @Published private(set) var state: State = .missing
    @Published private(set) var working = false
    @Published private(set) var checking = false
    @Published private(set) var selected: Bool
    struct Inspection {
        let state: State
        let detail: String
        let manifest: HelperManifest?
        init(state: State, detail: String = "", manifest: HelperManifest? = nil) {
            self.state = state; self.detail = detail; self.manifest = manifest
        }
    }
    private let defaults: UserDefaults
    private let installationTaskFactory: ((Bool) throws -> Process)?
    private let inspectInstallation: () throws -> Inspection
    private let requestInformation: (@escaping (Result<HelperInformation, Error>) -> Void) -> Void
    private let requestStart: (String, Bool, @escaping (Result<Int32, Error>) -> Void) -> Void
    private var availabilityCheck: (id: UUID, manifest: HelperManifest)?
    private var confirmedManifest: HelperManifest?
    private(set) var detail = ""
    private(set) var installationError: String?

    var usesHelper: Bool { selected && state == .ready }
    var installed: Bool { state != .missing }
    init(defaults: UserDefaults = .standard, makeInstallationTask: ((Bool) throws -> Process)? = nil,
         inspectInstallation: (() throws -> Inspection)? = nil,
         requestInformation: ((@escaping (Result<HelperInformation, Error>) -> Void) -> Void)? = nil,
         requestStart: ((String, Bool, @escaping (Result<Int32, Error>) -> Void) -> Void)? = nil) {
        self.defaults = defaults
        installationTaskFactory = makeInstallationTask
        self.inspectInstallation = inspectInstallation ?? Self.inspect
        let client = HelperClient(hash: HelperBuildIdentity.cdHash)
        self.requestInformation = requestInformation ?? client.status
        self.requestStart = requestStart ?? client.start
        selected = defaults.bool(forKey: "useInstalledHelper")
        refresh()
    }
    func refresh() { inspectAvailability() }

    private static func inspect() throws -> Inspection {
        guard let manifest = try HelperTrust.manifest() else {
            var info = stat()
            let filesPresent = lstat(HelperConstants.executable, &info) == 0 || lstat(HelperConstants.plist, &info) == 0
            return Inspection(state: filesPresent ? .unavailable : .missing)
        }
        guard manifest.ownerUID == getuid() else {
            return Inspection(state: .unavailable, detail: "The helper belongs to another Mac user.")
        }
        guard manifest.protocolVersion == HelperConstants.protocolVersion,
              manifest.clientHash == (try HelperTrust.signingHash()), manifest.helperHash == HelperBuildIdentity.cdHash,
              manifest.helperSHA256 == HelperBuildIdentity.sha256 else { return Inspection(state: .updateRequired) }
        guard let data = try HelperTrust.read(HelperConstants.executable, maximum: HelperConstants.maximumExecutableBytes, executable: true),
              HelperTrust.sha256(data) == HelperBuildIdentity.sha256,
              try HelperTrust.read(HelperConstants.plist) != nil else { return Inspection(state: .unavailable) }
        return Inspection(state: .ready, manifest: manifest)
    }

    private func inspectAvailability(installationFailure: ((String) -> Void)? = nil) {
        let confirmInstallation = installationFailure != nil
        guard !working else { return }
        let inspection: Inspection
        do { inspection = try inspectInstallation() }
        catch {
            applyUnavailable(error.localizedDescription)
            installationFailure?(error.localizedDescription)
            return
        }
        guard inspection.state == .ready, let manifest = inspection.manifest else {
            invalidateAvailabilityCheck()
            confirmedManifest = nil
            state = confirmInstallation || inspection.state == .ready ? .unavailable : inspection.state
            detail = inspection.detail
            installationFailure?("The installed helper identity could not be confirmed.")
            return
        }
        // A trusted file on disk does not establish that the daemon is usable.
        // Coalesce refreshes, but invalidate replies when the installation changes.
        if availabilityCheck?.manifest == manifest { return }
        let check = UUID()
        availabilityCheck = (check, manifest)
        checking = true
        if confirmedManifest != manifest { state = .unavailable }
        // Retain the last diagnostic while retrying, so Details can explain
        // the fallback before the new asynchronous response arrives.
        if confirmInstallation { working = true }
        requestInformation { [weak self] result in
            guard let self, self.availabilityCheck?.id == check,
                  !self.working || confirmInstallation else { return }
            self.invalidateAvailabilityCheck()
            if confirmInstallation { self.working = false }
            switch result {
            case .success(let information) where information.manifest == manifest && information.clientConfirmed:
                self.confirmedManifest = manifest
                self.state = .ready; self.detail = ""
            case .success:
                let message = "The installed helper identity could not be confirmed."
                self.applyUnavailable(message)
                installationFailure?(message)
            case .failure(let error):
                self.applyUnavailable(error.localizedDescription)
                installationFailure?(error.localizedDescription)
            }
        }
    }
    private func invalidateAvailabilityCheck() {
        availabilityCheck = nil
        checking = false
    }
    private func applyUnavailable(_ message: String) {
        invalidateAvailabilityCheck()
        confirmedManifest = nil
        state = .unavailable; detail = message
    }
    private func rememberSelection(_ enabled: Bool) {
        selected = enabled
        defaults.set(enabled, forKey: "useInstalledHelper")
    }
    func select(_ enabled: Bool) {
        guard !working, !enabled || state == .ready else { return }
        rememberSelection(enabled)
    }
    func start(path: String, restoreOnly: Bool, completion: @escaping (Result<Int32, Error>) -> Void) {
        requestStart(path, restoreOnly) { [weak self] result in
            if case .failure(let error) = result, !(error is HelperOperationRejection) {
                self?.applyUnavailable(error.localizedDescription)
            }
            completion(result)
        }
    }

    // The caller has explicitly selected the operation. The system still requests authorization.
    func requestInstallation(remove: Bool, onFailure: ((String) -> Void)? = nil) -> SessionOperationResult {
        guard !working else { return .rejected("Wait for the helper operation to finish.") }
        installationError = nil
        let reportFailure: (String) -> Void = { [weak self] message in
            self?.installationError = message
            onFailure?(message)
        }
        do {
            let task: Process
            if let installationTaskFactory { task = try installationTaskFactory(remove) }
            else { task = try HelperAuthorization.installationTask(remove: remove) }
            invalidateAvailabilityCheck()
            working = true
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
            try task.run()
            if !remove { confirmDuringInstallation(task) }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                DispatchQueue.main.async {
                    self.working = false
                    if task.terminationStatus == 0 {
                        // Successful installation is an explicit helper choice, even
                        // when the subsequent health/trust confirmation cannot finish.
                        self.rememberSelection(!remove)
                        self.confirmedManifest = nil
                        if remove { self.refresh() }
                        else { self.inspectAvailability(installationFailure: reportFailure) }
                    } else {
                        let output = String(decoding: data.prefix(8192), as: UTF8.self)
                        self.refresh()
                        if output.contains("-128") {
                            self.installationError = "macOS authorization was cancelled."
                        } else {
                            reportFailure(output.isEmpty ? "The helper operation failed." : output)
                        }
                    }
                }
            }
            return .pending("Confirm the macOS authorization prompt if it appears.")
        } catch {
            working = false
            refresh()
            reportFailure(error.localizedDescription)
            return .rejected(SessionMessage(reason: error.localizedDescription))
        }
    }

    private func confirmDuringInstallation(_ task: Process) {
        guard working, task.isRunning else { return }
        requestInformation { [weak self, weak task] _ in
            guard let self, let task, self.working, task.isRunning else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.confirmDuringInstallation(task) }
        }
    }

}
