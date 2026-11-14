import Foundation

@main struct SessionMessageTests {
    static func main() {
        let english: (String) -> String = { $0 }
        let russian: (String) -> String = { key in
            ["Session ended: %@.": "Сеанс завершён: %@.",
             "power adapter disconnected": "зарядка отключена",
             "The Wakecup timer ended. “Keep awake with lid closed” was not changed.": "Таймер истёк. Режим с закрытой крышкой не изменился.",
             "Could not connect to the Wakecup helper.": "Не удалось подключиться к помощнику Wakecup.",
             "The system command timed out. Try recovery again.": "macOS не отвечает на команду настройки сна.",
             "battery reached the %@%% threshold": "заряд достиг порога %@%%",
             "macOS could not prevent sleep (%@).": "macOS не разрешила удержание сна (%@).",
             "Could not launch the helper guard (%@).": "Не удалось запустить защитный процесс помощника (код %@).",
             "Helper installation failed and its previous installation could not be restored: %@": "Не удалось установить помощника и восстановить предыдущую установку: %@",
             "Could not change login at startup: %@": "Не удалось изменить автозапуск: %@"] [key] ?? key
        }
        let simple: SessionMessage = "The Wakecup timer ended. “Keep awake with lid closed” was not changed."
        expect(simple.text(using: english) == "The Wakecup timer ended. “Keep awake with lid closed” was not changed.", "String literal notice uses an English key")
        expect(simple.text(using: russian) == "Таймер истёк. Режим с закрытой крышкой не изменился.", "String literal notice re-renders")
        let notice = SessionMessage("Session ended: %@.", arguments: ["зарядка отключена"])
        expect(notice.text(using: english) == "Session ended: power adapter disconnected.", "English notice translates the stop reason")
        expect(notice.text(using: russian) == "Сеанс завершён: зарядка отключена.", "Stored notice renders in new language")
        let battery = SessionMessage("Session ended: %@.", arguments: ["заряд достиг порога 20%"])
        expect(battery.text(using: english) == "Session ended: battery reached the 20% threshold.", "Dynamic threshold translates")
        expect(battery.text(using: russian) == "Сеанс завершён: заряд достиг порога 20%.", "Threshold preserves percent sign")
        let code = SessionMessage(reason: "macOS не разрешила удержание сна (-536870199).")
        expect(code.text(using: english) == "macOS could not prevent sleep (-536870199).", "Dynamic macOS error translates")
        expect(code.text(using: russian) == "macOS не разрешила удержание сна (-536870199).", "macOS error re-renders")
        expect(SessionMessage(reason: "Не удалось прочитать настройки сна.").text(using: english) == "Could not read sleep settings.", "Known static system error translates")
        expect(SessionMessage(reason: "The system command timed out. Try recovery again.").text(using: russian)
               == "macOS не отвечает на команду настройки сна.", "New guardian errors translate without changing unknown OS errors")
        expect(SessionMessage(reason: "Could not connect to the Wakecup helper.").text(using: russian)
               == "Не удалось подключиться к помощнику Wakecup.", "Helper errors follow the selected language")
        let raw = "Disk error: /Volumes/время истекло, 100%"
        expect(SessionMessage(reason: raw).text(using: { _ in "incorrect replacement" }) == raw, "Unknown OS error stays verbatim")
        expect(SessionMessage("Could not change login at startup: %@", arguments: [raw]).text(using: english) == "Could not change login at startup: " + raw, "OS error argument is not partially translated or interpreted as format")
        let launchError = "Could not launch the helper guard (13)."
        let launchMessage = SessionMessage(reason: launchError)
        expect(launchMessage.text(using: english) == launchError, "English launch error preserves the code")
        expect(launchMessage.text(using: russian) == "Не удалось запустить защитный процесс помощника (код 13).",
               "Helper launch error translates with its error code")
        let rollbackPrefix = "Helper installation failed and its previous installation could not be restored: "
        let rollback = SessionMessage(reason: rollbackPrefix + "Could not connect to the Wakecup helper.")
        let russianRollbackPrefix = "Не удалось установить помощника и восстановить предыдущую установку: "
        expect(rollback.text(using: russian) == russianRollbackPrefix + "Не удалось подключиться к помощнику Wakecup.",
               "Rollback error translates a known nested reason")
        expect(SessionMessage(reason: rollbackPrefix + raw).text(using: russian) == russianRollbackPrefix + raw,
               "Rollback error preserves an unknown nested reason")
        for unknown in ["Could not launch the helper guard (unknown).", "заряд достиг порога 20% extra", "prefix macOS не разрешила удержание сна (-1).", "заряд достиг порога 999%"] {
            expect(SessionMessage(reason: unknown).text(using: { _ in "incorrect replacement" }) == unknown, "Template matching is exact")
        }
        print("PASS: session messages re-render with language, stop reasons, dynamic values, and verbatim OS errors")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: " + name) }
    }
}
