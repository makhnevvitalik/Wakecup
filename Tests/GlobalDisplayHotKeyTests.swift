import Foundation

@main
struct GlobalDisplayHotKeyTests {
    static func main() {
        var failures: [String] = []
        var count = 0
        func expect(_ condition: Bool, _ label: String) {
            count += 1
            if !condition { failures.append(label) }
        }
        var installed: [DisplayShortcut] = []
        var callbacks: [() -> Void] = []
        var cancelled = 0
        var refuse = false
        let registrar: GlobalDisplayHotKey.Registrar = { shortcut, handler in
            expect(Thread.isMainThread, "registration runs on main thread")
            if refuse { throw DisplayHotKeyError.conflict }
            installed.append(shortcut)
            callbacks.append(handler)
            return { cancelled += 1 }
        }
        var hotKey: GlobalDisplayHotKey? = GlobalDisplayHotKey(registrar: registrar)
        let first = DisplayShortcut(keyCode: 96, modifiers: DisplayShortcut.command | DisplayShortcut.shift)
        let second = DisplayShortcut(keyCode: 97, modifiers: DisplayShortcut.control)
        var calls = 0
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        do {
            try hotKey!.register(DisplayShortcut(keyCode: 63, modifiers: 8)) { calls += 100 }
            expect(false, "invalid shortcut must throw")
        } catch { expect(error as? DisplayHotKeyError == .invalid, "invalid shortcut reports stable invalid error") }
        expect(installed.isEmpty, "invalid shortcut never reaches native registration")
        do {
            try hotKey!.register(first) { expect(Thread.isMainThread, "callback runs on main thread"); calls += 1 }
            callbacks[0](); drain()
            expect(calls == 1, "registered handler receives the chord")
            try hotKey!.register(first) { calls += 2 }
            expect(installed.count == 1 && cancelled == 0, "same chord replaces callback without conflicting with itself")
            callbacks[0](); drain()
            expect(calls == 3, "same chord uses the updated callback")
            refuse = true
            do { try hotKey!.register(second) { calls += 100 }; expect(false, "native conflict must throw") }
            catch { expect(error as? DisplayHotKeyError == .conflict, "native conflict remains visible") }
            callbacks[0](); drain()
            expect(calls == 5 && cancelled == 0, "failed replacement retains old usable registration")
            refuse = false
            callbacks[0]()
            try hotKey!.register(second) { calls += 10 }
            drain()
            expect(calls == 5 && cancelled == 1, "replacement invalidates queued callback and unregisters old chord")
            callbacks[1](); drain()
            expect(calls == 15, "replacement chord works")
            callbacks[1]()
            hotKey!.unregister(); hotKey!.unregister(); drain()
            expect(calls == 15 && cancelled == 2, "unregister is idempotent and suppresses queued callback")
            callbacks[1](); drain()
            expect(calls == 15, "late native callback cannot invoke an unregistered action")
            try hotKey!.register(first) { calls += 100 }
            callbacks[2]()
            hotKey = nil; drain()
            expect(calls == 15 && cancelled == 3, "deinit cancels exactly once and suppresses pending callbacks")
        } catch { expect(false, "unexpected registration error: \(error)") }
        expect(DisplayHotKeyError.conflict.localizedDescription == "display.shortcut.conflict", "error preserves localization key")
        print("Global display hotkey checks: \(count), failures: \(failures.count)")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
