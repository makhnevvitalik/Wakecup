import Foundation

// Owns session power effects and guardian control writes independently of the UI.
final class SessionPowerResources {
    private struct Scope {
        let id: String
        var level: ThermalStopLevel
        var files: SessionFiles?
        let onThermalStop: (String) -> Void
        var thermalStopped = false
        var guardianStopRequested = false
        var thermalStopWritten = false
        var ended = false
    }

    private let queue = DispatchQueue(label: "local.wakecup.session-power", qos: .userInitiated)
    private let startAssertions: (Bool) throws -> Void
    private let stopAssertions: () -> Void
    private let readThermalState: () -> ProcessInfo.ThermalState
    // This closure enqueues brightness restoration on its own queue.
    private let restoreAfterThermalStop: () -> Void
    private var scope: Scope?
    private var holdingAssertions = false

    init(startAssertions: @escaping (Bool) throws -> Void, stopAssertions: @escaping () -> Void,
         readThermalState: @escaping () -> ProcessInfo.ThermalState, restoreAfterThermalStop: @escaping () -> Void) {
        self.startAssertions = startAssertions
        self.stopAssertions = stopAssertions
        self.readThermalState = readThermalState
        self.restoreAfterThermalStop = restoreAfterThermalStop
    }

    func checkStart(level: ThermalStopLevel, continuing: Bool) throws {
        try queue.sync { try validateStart(level: level, continuing: continuing) }
    }

    func begin(id: String, level: ThermalStopLevel, files: SessionFiles?, continuing: Bool,
               onThermalStop: @escaping (String) -> Void) throws {
        try queue.sync {
            try validateStart(level: level, continuing: continuing)
            if !continuing { releaseAssertions() }
            scope = Scope(id: id, level: level, files: files, onThermalStop: onThermalStop)
        }
    }

    private func validateStart(level: ThermalStopLevel, continuing: Bool) throws {
        if scope?.ended == true {
            finishEndedScope()
            guard scope == nil else { throw SessionTermination.thermal }
        }
        let temperature = readThermalState()
        if continuing {
            guard scope != nil else { throw Self.inactive }
            observeThermalStop(at: temperature)
            guard scope?.thermalStopped == false else { throw SessionTermination.thermal }
            if level.reached(by: temperature) {
                latchThermalStop()
                throw SessionTermination.thermal
            }
        } else if level.reached(by: temperature) {
            throw SessionTermination.thermal
        }
    }

    func checkTemperature() {
        queue.sync {
            guard let scope else { return }
            if scope.ended { finishEndedScope() }
            else { observeThermalStop(at: readThermalState()) }
        }
    }

    func acceptThermalStop(for id: String) {
        queue.sync {
            guard scope?.id == id else { return }
            latchThermalStop()
        }
    }

    func hasThermalStop(for id: String) -> Bool {
        queue.sync { scope?.id == id && scope?.thermalStopped == true }
    }

    func holdAssertions(display: Bool) throws {
        try queue.sync {
            try requireRunningScope()
            try startAssertions(display)
            holdingAssertions = true
        }
    }

    func end(id: String?) {
        queue.sync {
            guard let id, scope?.id == id else { return }
            releaseAssertions()
            scope?.ended = true
            finishEndedScope()
        }
    }

    private func finishEndedScope() {
        guard let scope, scope.ended else { return }
        if scope.thermalStopped, !scope.thermalStopWritten, let files = scope.files,
           (try? files.read("status.json", as: SessionStatus.self))?.phase.isTerminal != true {
            // A failed control write must survive UI cleanup. Pending authorization
            // can otherwise launch the guardian after the temperature falls.
            try? writeThermalStopIfNeeded()
            guard self.scope?.thermalStopWritten == true else { return }
        }
        self.scope = nil
    }

    func darkeningPermission() -> BacklightDarkeningPermission {
        let id = queue.sync { scope?.id }
        return { [weak self] write in
            guard let self, let id else { throw Self.inactive }
            try self.queue.sync {
                guard self.scope?.id == id else { throw Self.inactive }
                try self.requireRunningScope()
                try write()
            }
        }
    }

    func setThermalLevel(_ level: ThermalStopLevel) throws {
        try queue.sync {
            guard let current = scope else { return }
            try requireRunningScope()
            if let files = current.files {
                var control = try readControl(files)
                try rejectStopped(control)
                control.thermalStopLevel = level
                try files.write(control, to: "control.json")
            }
            scope?.level = level
            observeThermalStop(at: readThermalState())
        }
    }

    func updateGuardianSettings(_ update: SessionLiveUpdate, files: SessionFiles) throws {
        try queue.sync {
            guard owns(files) else { throw Self.inactive }
            try requireRunningScope()
            var control = try readControl(files)
            try rejectStopped(control)
            control.update = update
            try files.write(control, to: "control.json")
        }
    }

    func sendGuardianStop(_ files: SessionFiles) throws {
        try queue.sync {
            let current = owns(files)
            if current { scope?.guardianStopRequested = true }
            let thermal = current && scope?.thermalStopped == true
            try writeGuardianStop(files, thermal: thermal)
            if thermal {
                scope?.thermalStopWritten = true
                finishEndedScope()
            }
        }
    }

    func discardFinished(_ files: SessionFiles) -> Bool {
        queue.sync {
            // Keep the terminal reason if this removes the last guardian record.
            if owns(files), guardianReportedThermalStop(files) { latchThermalStop() }
            guard files.removeIfFinished() else { return false }
            if owns(files) {
                scope?.files = nil
                finishEndedScope()
            }
            return true
        }
    }

    func discardUnstarted(_ files: SessionFiles) -> Bool {
        queue.sync {
            guard files.removeIfUnstarted() else { return false }
            if owns(files) {
                scope?.files = nil
                finishEndedScope()
            }
            return true
        }
    }

    private static let inactive = WakecupError(message: "The session is no longer active.")

    private func owns(_ files: SessionFiles) -> Bool { scope?.files?.identity == files.identity }

    private func readControl(_ files: SessionFiles) throws -> SessionControl {
        try files.read("control.json", as: SessionControl.self)
    }

    private func rejectStopped(_ control: SessionControl) throws {
        if control.thermalStopRequested == true { throw SessionTermination.thermal }
        if control.stop { throw Self.inactive }
    }

    private func requireRunningScope() throws {
        guard scope?.ended == false else { throw Self.inactive }
        observeThermalStop(at: readThermalState())
        if scope?.thermalStopped == true { throw SessionTermination.thermal }
        if scope?.guardianStopRequested == true { throw Self.inactive }
    }

    private func guardianReportedThermalStop(_ files: SessionFiles) -> Bool {
        (try? files.read("status.json", as: SessionStatus.self))?.reasonCode == .thermal
    }

    private func observeThermalStop(at temperature: ProcessInfo.ThermalState) {
        guard let scope else { return }
        if scope.thermalStopped {
            try? writeThermalStopIfNeeded()
        } else if scope.level.reached(by: temperature) || scope.files.map(guardianReportedThermalStop) == true {
            latchThermalStop()
        }
    }

    private func latchThermalStop() {
        guard let current = scope, !current.thermalStopped else { return }
        scope?.thermalStopped = true
        releaseAssertions()
        restoreAfterThermalStop()
        try? writeThermalStopIfNeeded()
        DispatchQueue.main.async { current.onThermalStop(current.id) }
    }

    private func writeThermalStopIfNeeded() throws {
        guard let scope, scope.thermalStopped, !scope.thermalStopWritten, let files = scope.files else { return }
        try writeGuardianStop(files, thermal: true)
        self.scope?.thermalStopWritten = true
    }

    private func writeGuardianStop(_ files: SessionFiles, thermal: Bool) throws {
        // A terminal stop must fence a late guardian even when its control record was lost.
        var control = (try? readControl(files)) ?? SessionControl()
        guard !control.stop || (thermal && control.thermalStopRequested != true) else { return }
        control.stop = true
        if thermal { control.thermalStopRequested = true }
        try files.write(control, to: "control.json")
    }

    private func releaseAssertions() {
        guard holdingAssertions else { return }
        stopAssertions()
        holdingAssertions = false
    }
}
