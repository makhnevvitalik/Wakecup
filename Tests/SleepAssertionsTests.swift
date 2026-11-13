import Foundation
import IOKit.pwr_mgt

// All assertion operations are fake: no real sleep/display setting changes.
@main struct SleepAssertionsTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        var nextID: IOPMAssertionID = 1
        var live = Set<IOPMAssertionID>()
        var released: [IOPMAssertionID] = []
        var failingType: String?
        let assertions = SleepAssertions(create: { type in
            if type == failingType { throw WakecupError(message: "controlled assertion failure") }
            let id = nextID; nextID += 1
            live.insert(id)
            return id
        }, release: { id in
            released.append(id)
            live.remove(id)
        })
        try assertions.start(display: false)
        let system = assertions.ids[0]
        try assertions.start(display: true)
        try expect(assertions.ids.count == 2 && assertions.ids[0] == system && released.isEmpty,
                   "Enabling display must retain the original system assertion without releasing it")
        let display = assertions.ids[1]
        try assertions.start(display: true)
        try expect(assertions.ids == [system, display] && nextID == 3, "Repeated enable must not create duplicate assertions")
        try assertions.start(display: false)
        try expect(assertions.ids == [system] && live == [system] && released == [display],
                   "Disabling display must release only the display assertion")
        try assertions.start(display: false)
        try expect(released == [display], "Repeated disable must be idempotent")
        failingType = kIOPMAssertionTypePreventUserIdleDisplaySleep
        do {
            try assertions.start(display: true)
            throw WakecupError(message: "Display creation should fail")
        } catch let error as WakecupError {
            try expect(error.message == "controlled assertion failure", "Failure was not propagated")
        }
        try expect(assertions.ids == [system] && live == [system] && released == [display],
                   "Failed display changes must keep the system assertion alive")
        assertions.stop()
        try expect(assertions.ids.isEmpty && live.isEmpty, "Stop must release all remaining assertions")
        let releases = released
        assertions.stop()
        try expect(released == releases, "Repeated stop must not release stale IDs")
        do {
            try assertions.start(display: true)
            throw WakecupError(message: "Initial display creation should fail")
        } catch let error as WakecupError {
            try expect(error.message == "controlled assertion failure", "Initial failure was not propagated")
        }
        try expect(assertions.ids.isEmpty && live.isEmpty, "Initial startup failure must clean up its newly created system assertion")
        failingType = nil
        try assertions.start(display: true)
        try expect(assertions.ids.count == 2 && live.count == 2, "Startup can recover after a failed display assertion")
        assertions.stop()
        var owned: SleepAssertions? = SleepAssertions(create: { _ in
            let id = nextID; nextID += 1; live.insert(id); return id
        }, release: { live.remove($0) })
        try owned?.start(display: true)
        owned = nil
        try expect(live.isEmpty, "Deinit must release both owned assertions")
        print("PASS: live display assertion changes preserve system assertion identity, are idempotent, roll back safely and clean up")
    }
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw WakecupError(message: message) }
    }
}
