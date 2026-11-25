import Foundation
import IOKit.pwr_mgt

final class SleepAssertions {
    private var systemID: IOPMAssertionID?
    private var displayID: IOPMAssertionID?
    private let createAssertion: (String) throws -> IOPMAssertionID
    private let releaseAssertion: (IOPMAssertionID) -> Void
    var ids: [IOPMAssertionID] { [systemID, displayID].compactMap { $0 } }

    init(create: @escaping (String) throws -> IOPMAssertionID = { type in
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Wakecup: активный сеанс" as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw WakecupError(message: "macOS не разрешила удержание сна (\(result)).")
        }
        return id
    }, release: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }) {
        createAssertion = create
        releaseAssertion = release
    }

    // Repeated starts update only display sleep. Keep the system assertion alive
    // throughout a live change; an unsuccessful update retains the old state.
    func start(display: Bool) throws {
        let starting = systemID == nil
        do {
            if starting { systemID = try createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep) }
            if display, displayID == nil {
                displayID = try createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep)
            } else if !display, let id = displayID {
                releaseAssertion(id)
                displayID = nil
            }
        } catch {
            if starting { stop() }
            throw error
        }
    }

    func stop() {
        ids.forEach(releaseAssertion)
        systemID = nil
        displayID = nil
    }

    deinit { stop() }
}
