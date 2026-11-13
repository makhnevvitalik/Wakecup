import Foundation
import Carbon

enum DisplayHotKeyError: LocalizedError, Equatable {
    case invalid
    case conflict
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalid: return "display.shortcut.invalid"
        case .conflict: return "display.shortcut.conflict"
        case .unavailable: return "display.shortcut.unavailable"
        }
    }
}

/// Owns only the currently armed restore chord. It never observes raw keys.
final class GlobalDisplayHotKey {
    typealias Registrar = (DisplayShortcut, @escaping () -> Void) throws -> (() -> Void)

    private let registrar: Registrar
    private var cancellation: (() -> Void)?
    private var callback: Callback?
    private var shortcut: DisplayShortcut?

    convenience init() {
        self.init(registrar: { shortcut, handler in
            let registration = try NativeDisplayHotKey(shortcut: shortcut, handler: handler)
            return { registration.unregister() }
        })
    }

    /// Injection keeps lifecycle and failure tests free of real global shortcuts.
    init(registrar: @escaping Registrar) { self.registrar = registrar }

    func register(_ shortcut: DisplayShortcut, handler: @escaping () -> Void) throws {
        try Self.onMain {
            guard shortcut.isValid else { throw DisplayHotKeyError.invalid }
            if self.shortcut == shortcut, let callback = self.callback {
                callback.replace(with: handler)
                return
            }
            let callback = Callback(handler)
            let cancellation = try registrar(shortcut) { [weak callback] in callback?.invoke() }
            // A failed replacement leaves the old registered action usable.
            unregisterOnMain()
            self.shortcut = shortcut
            self.callback = callback
            self.cancellation = cancellation
        }
    }

    func unregister() { Self.onMain { unregisterOnMain() } }

    static func validate(_ shortcut: DisplayShortcut) throws {
        let candidate = GlobalDisplayHotKey()
        try candidate.register(shortcut, handler: {})
        candidate.unregister()
    }

    private func unregisterOnMain() {
        callback?.invalidate()
        callback = nil
        shortcut = nil
        let cancel = cancellation
        cancellation = nil
        cancel?()
    }

    deinit {
        callback?.invalidate()
        let cancel = cancellation
        if Thread.isMainThread { cancel?() }
        else { DispatchQueue.main.async { cancel?() } }
    }

    // Carbon hotkey APIs are explicitly not thread safe.
    private static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    private final class Callback {
        private let lock = NSLock()
        private var handler: (() -> Void)?

        init(_ handler: @escaping () -> Void) { self.handler = handler }
        func replace(with handler: @escaping () -> Void) {
            lock.lock(); self.handler = handler; lock.unlock()
        }
        func invalidate() { lock.lock(); handler = nil; lock.unlock() }
        func invoke() {
            // Also protects against a queued native notification after teardown.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let handler = self.handler; self.lock.unlock()
                handler?()
            }
        }
    }
}

private final class NativeDisplayHotKey {
    private static var nextID: UInt32 = 0
    private static let signature: OSType = 0x57434450 // WCDP
    private let id: EventHotKeyID
    private var handler: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(shortcut: DisplayShortcut, handler: @escaping () -> Void) throws {
        guard shortcut.isValid else { throw DisplayHotKeyError.invalid }
        Self.nextID &+= 1
        id = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        self.handler = handler
        var carbonModifiers: UInt32 = 0
        if shortcut.modifiers & DisplayShortcut.shift != 0 { carbonModifiers |= UInt32(shiftKey) }
        if shortcut.modifiers & DisplayShortcut.control != 0 { carbonModifiers |= UInt32(controlKey) }
        if shortcut.modifiers & DisplayShortcut.option != 0 { carbonModifiers |= UInt32(optionKey) }
        if shortcut.modifiers & DisplayShortcut.command != 0 { carbonModifiers |= UInt32(cmdKey) }
        try Self.checkSystemShortcuts(keyCode: shortcut.keyCode, modifiers: carbonModifiers)

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            let registration = Unmanaged<NativeDisplayHotKey>.fromOpaque(data).takeUnretainedValue()
            var received = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &received)
            guard status == noErr,
                  received.signature == registration.id.signature,
                  received.id == registration.id.id,
                  let handler = registration.handler else { return OSStatus(eventNotHandledErr) }
            handler()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr, eventHandler != nil else {
            unregister()
            throw DisplayHotKeyError.unavailable
        }
        // The default Carbon registration is shared; exclusive is necessary
        // for its conflict result to protect an exit action from another owner.
        let registered = RegisterEventHotKey(shortcut.keyCode, carbonModifiers, id,
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr, hotKey != nil else {
            unregister()
            throw registered == eventHotKeyExistsErr ? DisplayHotKeyError.conflict : .unavailable
        }
    }

    private static func checkSystemShortcuts(keyCode: UInt32, modifiers: UInt32) throws {
        var value: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&value) == noErr, let value else { throw DisplayHotKeyError.unavailable }
        guard let keys = value.takeRetainedValue() as? [[String: Any]] else { throw DisplayHotKeyError.unavailable }
        for key in keys {
            if (key[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
               (key[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == keyCode,
               (key[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == modifiers {
                throw DisplayHotKeyError.conflict
            }
        }
    }

    func unregister() {
        handler = nil
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    deinit { unregister() }
}
