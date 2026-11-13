import Foundation

/// Keeps notices independent of the selected UI language. Protocol reasons stay unchanged on disk.
struct SessionMessage: ExpressibleByStringLiteral {
    let key: String
    let arguments: [String]
    private let isReason: Bool

    init(_ key: String, arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
        isReason = false
    }

    init(stringLiteral value: String) { self.init(value) }

    /// Only known application reasons are translated; arbitrary system errors stay verbatim.
    init(reason: String) {
        key = reason
        arguments = []
        isReason = true
    }

    func text(using localize: (String) -> String) -> String {
        if isReason { return Self.reasonText(key, using: localize) }
        let template = localize(key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, arguments: arguments.map { Self.reasonText($0, using: localize) })
    }

    private static func reasonText(_ reason: String, using localize: (String) -> String) -> String {
        if let key = reasonKeys[reason] { return localize(key) }
        if reasonKeys.values.contains(reason) || guardianReasonKeys.contains(reason) { return localize(reason) }
        if let value = number(in: reason, prefix: "заряд достиг порога ", suffix: "%"),
           let threshold = Int(value), (0...100).contains(threshold) {
            return String(format: localize("battery reached the %@%% threshold"), value)
        }
        if let value = number(in: reason, prefix: "macOS не разрешила удержание сна (", suffix: ")."),
           Int32(value) != nil {
            return String(format: localize("macOS could not prevent sleep (%@)."), value)
        }
        return reason
    }

    private static func number(in text: String, prefix: String, suffix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix), text.count > prefix.count + suffix.count else { return nil }
        let value = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        let digits = value.hasPrefix("-") ? value.dropFirst() : value[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return value
    }

    private static let guardianReasonKeys: Set<String> = [
        "The helper belongs to another Mac user.",
        "The installed helper identity could not be confirmed.",
        "Invalid administrator execution request.",
        "The operation must run from a verified system staging file.",
        "Recovery is already in progress. Check the session status before trying again.",
        "Could not prepare the recovery result.",
        "Could not isolate recovery result descriptors.",
        "Invalid recovery completion request.",
        "Could not confirm recovery completion.",
        "Invalid helper session path.",
        "The session does not belong to the requesting Wakecup process.",
        "Invalid helper signing identity.",
        "Invalid helper response.",
        "Invalid helper guard response.",
        "The helper connection ended. Check the session status before trying again.",
        "The helper connection was interrupted. Check the session status before trying again.",
        "Could not connect to the Wakecup helper.",
        "The helper did not reply. Check the session status before trying again.",
        "The helper is already processing another session.",
        "The Wakecup helper needs an update.",
        "The Wakecup connection is no longer valid.",
        "This session has already been started. Check its current status.",
        "The system helper identity is invalid.",
        "The Wakecup connection ended.",
        "Could not prepare the helper guard.",
        "Could not prepare helper descriptors.",
        "Could not isolate the helper guard.",
        "Could not isolate helper descriptors.",
        "Invalid administrator installation request.",
        "The installer must run from a verified system staging file.",
        "Stop Wakecup and restore normal sleep before changing the helper.",
        "Stop the active Wakecup guardian before changing the helper.",
        "Could not stop the installed Wakecup helper.",
        "Could not register the Wakecup helper.",
        "The installed Wakecup helper was not registered.",
        "The new helper did not authenticate with Wakecup. The previous installation has been restored.",
        "Could not remove the Wakecup helper file.",
        "Could not stage a Wakecup helper file.",
        "Could not write a Wakecup helper file.",
        "Could not commit a Wakecup helper file.",
        "Could not verify helper signature.",
        "Could not verify the running Wakecup signature.",
        "The helper signature is invalid.",
        "Hardened Runtime is required for the Wakecup helper.",
        "Unsafe helper signing entitlements.",
        "Could not open the installed helper.",
        "Unsafe installed helper permissions.",
        "Installed helper file is too large.",
        "Invalid system helper access permissions.",
        "The system helper location has additional access grants. Installation was refused.",
        "Could not prepare private helper permissions.",
        "Could not clear inherited helper access permissions.",
        "Invalid installed helper identity.",
        "The helper session changed before it could start.",
        "Invalid managed guard context.",
        "Could not restore sleep. Try recovery again; if it still fails, use the manual recovery guide.",
        "Automatic recovery could not establish exclusive ownership. Try recovery again; if it still fails, use the manual recovery guide.",
        "Another guardian or recovery operation owns the sleep setting. Try again after it stops.",
        "A previous system command has not stopped. Try recovery again.",
        "The system command timed out. Try recovery again.",
        "Invalid system command timeout.",
        "Could not create the system command pipe.",
        "Could not prepare the system command.",
        "Could not identify the system command.",
        "Could not open the guardian status socket.",
        "Could not open the system sleep lease.",
        "Invalid system sleep lease permissions.",
        "Could not acquire the system sleep lease.",
        "Could not read the system sleep owner.",
        "Invalid system sleep owner record.",
        "Could not save the system sleep owner.",
        "Could not identify the current boot session.",
        "Could not verify the guardian process.",
        "Could not verify guardian subprocesses.",
        "Could not stop the unresponsive guardian.",
    ]

    private static let reasonKeys: [String: String] = [
        "порог заряда должен быть от 10% до 90%": "battery threshold must be between 10% and 90%",
        "не удалось прочитать состояние питания": "could not read power state",
        "зарядка отключена": "power adapter disconnected",
        "не удалось определить заряд аккумулятора": "could not determine battery charge",
        "Не удалось открыть каталог сеанса.": "Could not open the session directory.",
        "Недопустимые права каталога сеанса.": "Invalid session directory permissions.",
        "Неизвестный файл сеанса.": "Unknown session file.",
        "Не удалось прочитать состояние сеанса.": "Could not read session state.",
        "Недопустимый файл состояния сеанса.": "Invalid session state file.",
        "Состояние сеанса слишком велико.": "Session state is too large.",
        "Не удалось сохранить состояние сеанса.": "Could not save session state.",
        "Не удалось установить владельца файла сеанса.": "Could not set the session file owner.",
        "Ошибка записи состояния сеанса.": "Could not write session state.",
        "Не удалось зафиксировать состояние сеанса.": "Could not commit session state.",
        "Длительность должна быть от 1 секунды до 999 часов.": "Duration must be between 1 second and 999 hours.",
        "Некорректные параметры сеанса.": "Invalid session parameters.",
        "остановлено": "stopped",
        "приложение закрыто": "application closed",
        "защитный процесс завершён": "guardian exited",
        "Не удалось прочитать настройки сна.": "Could not read sleep settings.",
        "Неизвестное значение SleepDisabled.": "Unknown SleepDisabled value.",
        "pmset не прочитал настройки.": "pmset could not read settings.",
        "Сон уже отключён другой настройкой. Сеанс не запущен.": "Sleep is already disabled by another setting. The session was not started.",
        "macOS не включила режим закрытой крышки.": "macOS could not enable closed-lid mode.",
        "Не удалось вернуть режим сна. Нужна команда восстановления: sudo pmset disablesleep 0": "Could not restore sleep. Recovery command required: sudo pmset disablesleep 0",
        "Нужны права администратора.": "Administrator privileges are required.",
        "Нет прерванного сеанса для восстановления.": "There is no interrupted session to recover.",
        "Не удалось восстановить сон.": "Could not restore sleep.",
        "сон восстановлен после прерванного сеанса": "sleep restored after an interrupted session",
        "Не удалось установить идентичность процессов сеанса.": "Could not establish session process identities.",
        "Датчик крышки недоступен.": "The lid sensor is unavailable.",
        "Не удалось изменить режим сна.": "Could not change sleep mode.",
        "запуск отменён": "start cancelled",
        "Сон уже отключён системной настройкой. Wakecup не будет менять чужое состояние.": "Sleep is already disabled by a system setting. Wakecup will not change an existing setting.",
    ]
}
