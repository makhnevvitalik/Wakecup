import AppKit

// Правила применения типографики для Wakecup и Language Switcher Plus/Dev:
// • Роль выбирается по задаче текста и уровню вёрстки, включая соседние элементы.
//   Тип кнопки (.link/.bordered), цвет и расположение справа сами по себе не задают размер.
// • Font описывает только шрифт. Цвет, размеры контрола и отступы задаются отдельно.
// • Общие роли сохраняют одинаковые имена и параметры между приложениями.
//   Роли могут ссылаться на одну базу, сохраняя отдельный смысл.
// • Своя роль допустима для отдельного типа содержимого/ввода: время HH:mm,
//   статус работы, Start/Stop, таймер в строке меню. В комментарии указываем
//   назначение, пример и правила состояний; используем существующую шкалу, где она подходит.
// • Новую роль не создаём только ради другого окна. Сначала проверяем существующие роли.
// • Для нового использования проверяем RU/EN, длинный текст, фокус и ошибку ввода.
//   Системные диалоги и внутреннюю типографику нативных виджетов оставляем системе.
// SwiftUI использует те же NSFont через Font(...), без отдельной локальной шкалы.
enum AppStyle {
    enum Font {
        // Имя приложения в основной шапке. Semibold 16.
        static let appName = NSFont.systemFont(ofSize: 16, weight: .semibold)
        // Главный заголовок отдельного окна: лицензия, инструкция, возврат яркости.
        // Semibold 20. Заголовки разделов внутри окна используют роли ниже.
        static let windowTitle = NSFont.systemFont(ofSize: 20, weight: .semibold)
        // Заголовок группы настроек или раздела инструкции: «Режим работы».
        // Medium 13, как в Language Switcher.
        static let sectionTitle = emphasizedBody
        // Основной текст: подписи строк, описание настройки, текст инструкции. Regular 13.
        // Цвет второстепенного текста задаётся отдельно и сам по себе не уменьшает шрифт.
        static let body = NSFont.systemFont(ofSize: 13)
        // Акцент в основном тексте: значение порога заряда, ссылка на восстановление.
        // Medium 13. Сохраняет размер соседнего основного текста.
        static let emphasizedBody = NSFont.systemFont(ofSize: 13, weight: .medium)
        // Пояснение, подсказка, подробность ошибки или дополнительная подпись. Regular 12.
        // Примеры: подпись под «Помощником», текущий заряд и инструкция под полем сочетания.
        static let supportingText = NSFont.systemFont(ofSize: 12)
        // Текст обычного действия или значения: «Настроить…», «Применить», списки и пресеты.
        // Regular 13. Оформление кнопки и её размер задаются независимо от шрифта.
        static let controlLabel = body
        // Статус работы и ссылка на обновление в шапке, результат проверки в About.
        // Regular 13, как в Language Switcher. Цвет состояния задаётся отдельно.
        static let statusText = body
        // Компактные ссылки текущего About и инструкции: GitHub, лицензия, отдельная инструкция.
        // Regular 12. Новые действия выбирают роль по позиции, а не только по виду ссылки.
        static let secondaryAction = supportingText
        // Номер версии в шапке, copyright и автор в About. Regular 12.
        // Роль описывает текст, а не задаёт его цвет или выравнивание.
        static let metadata = supportingText
        // Моноширинный текст команд восстановления сна. Regular 12.
        // Текст лицензии и обычные пояснения используют body (13), а не эту роль.
        static let monospacedBody = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Короткое оставшееся время возле значка в строке меню: «3ч». Tabular digits, medium 12.
        // Это компактная системная область, не шрифт таймера/поля в основном окне.
        static let menuBarCountdown = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        // Цифровое поле «Остановить в»: HH:mm. Tabular digits, regular, размер body (13).
        // Одинаковая типографика для обычного ввода, редактирования и ошибки.
        static let durationInput = NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        // Подпись главной кнопки Start/Stop и её переходных состояний. Rounded semibold 17.
        // Специальная роль для основной команды; кнопки диалогов используют controlLabel.
        static let primaryAction = rounded(size: 17, weight: .semibold)
        // Символ «!» внутри маленького предупреждающего значка в строке меню. Bold 7.
        // Часть рисунка иконки, а не размер пояснений или другого читаемого UI-текста.
        static let warningBadge = NSFont.systemFont(ofSize: 7, weight: .bold)

        private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            return font.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: size) } ?? font
        }
    }

    enum Icon {
        static let brandSize = NSSize(width: 40, height: 40)
        static let brandVisibleFraction: CGFloat = 0.80
        static let sectionSymbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Font.sectionTitle.pointSize, weight: .medium)
        static let settingsPointSize: CGFloat = 16
        static let menuBarSize = NSSize(width: 18, height: 18)
        static let menuBarCupSize = NSSize(width: 18, height: 14.4)
        static let recoveryBadgeDiameter: CGFloat = 8

        static func brandImage(_ artwork: NSImage, size: NSSize) -> NSImage {
            // Normalized bounds of the solid silhouette, measured without its shadow.
            let silhouette = NSRect(x: 0.044, y: 0.050, width: 0.913, height: 0.898)
            return NSImage(size: size, flipped: false) { rect in
                let side = min(rect.width, rect.height) * brandVisibleFraction
                let scale = side / max(silhouette.width, silhouette.height)
                artwork.draw(in: NSRect(x: rect.midX - silhouette.midX * scale,
                                        y: rect.midY - silhouette.midY * scale,
                                        width: scale, height: scale))
                return true
            }
        }

    }

    enum Layout {
        static let panelInset: CGFloat = 10
        static let cardSpacing: CGFloat = 8
        static let cardInset: CGFloat = 14
        static let cardCornerRadius: CGFloat = 11
        static let sectionHeaderHeight: CGFloat = 30
        static let rowHeight: CGFloat = 40
        static let rowItemSpacing: CGFloat = 10
        static let headerIconFrame: CGFloat = 40
        static let headerHeight: CGFloat = 44
        static let headerItemSpacing: CGFloat = 10
        static let headerHorizontalInset: CGFloat = 4
        static let headerVersionSpacing: CGFloat = 6
        static let headerStatusSpacing: CGFloat = 1
        static let headerStatusHeight: CGFloat = 16
        static let settingsButtonSize = NSSize(width: 34, height: 30)
        static let windowInset: CGFloat = 24
        static let windowTopInset: CGFloat = 20
    }

    enum HelperDialogLayout {
        static let width: CGFloat = 560
        static let iconSize: CGFloat = 48
        static let maximumTextHeight: CGFloat = 300
        static let spacing: CGFloat = 16
        static let buttonSpacing: CGFloat = 8
    }

    enum CalendarLayout {
        // AppKit's graphical date picker has a fixed 139×148-point layout;
        // its controlSize and font don't enlarge the calendar grid.
        static let magnification: CGFloat = 1.05
    }

    enum AboutLayout {
        static let width: CGFloat = 400
        static let iconSize: CGFloat = 56
        static let headerSpacing: CGFloat = 14
        static let versionSpacing: CGFloat = 4
        static let contentSpacing: CGFloat = 8
        static let actionSpacing: CGFloat = 12
        static let statusHeight: CGFloat = 16
        static let statusFooterSpacing: CGFloat = 6
        static let updateButtonWidth: CGFloat = 170
        static let bottomInset: CGFloat = 16
    }

    enum Color {
        static let accent = NSColor.controlAccentColor
        static let success = NSColor(name: "SuccessStatus") { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(calibratedRed: 0.44, green: 0.79, blue: 0.55, alpha: 1)
            }
            return NSColor(calibratedRed: 0.10, green: 0.43, blue: 0.23, alpha: 1)
        }
        static let cardBackground = NSColor.controlBackgroundColor
        static let cardBackgroundOpacity: Double = 0.8
        static let recoveryBadge = NSColor(calibratedRed: 1, green: 0.55, blue: 0.05, alpha: 1)
    }
}

extension AppStyle {
    static func commitActiveFieldEditor(in window: NSWindow?) {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
        window.makeFirstResponder(nil)
    }

    static func showWithoutInitialControlFocus(_ window: NSWindow) {
        let wasVisible = window.isVisible
        window.makeKeyAndOrderFront(nil)
        if !wasVisible {
            window.makeFirstResponder(nil)
        }
    }

    static func clearUnchangedFocus(in window: NSWindow, after event: NSEvent, previous: NSResponder?) {
        guard event.type == .leftMouseDown || event.type == .rightMouseDown,
              window.isVisible, window.firstResponder === previous,
              (previous as? NSTextView)?.isFieldEditor != true else { return }
        window.makeFirstResponder(nil)
    }

    final class InformationWindow: NSWindow {
        override func sendEvent(_ event: NSEvent) {
            super.sendEvent(event)
            if event.type == .leftMouseDown, isVisible {
                makeFirstResponder(nil)
            }
        }
    }

    final class SettingsMenuButton: NSPopUpButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let previousRing = focusRingType
            focusRingType = .none
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
            if let window, window.firstResponder === self {
                window.makeFirstResponder(nil)
            }
            focusRingType = previousRing
        }
    }

    static func makeAboutIdentityView(name: String, availableWidth: CGFloat) -> NSStackView {
        let title = NSTextField(wrappingLabelWithString: name)
        title.isSelectable = false
        title.font = Font.windowTitle
        title.preferredMaxLayoutWidth = availableWidth

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AboutLayout.versionSpacing
        title.widthAnchor.constraint(lessThanOrEqualToConstant: availableWidth).isActive = true

        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            let label = NSTextField(wrappingLabelWithString: version)
            label.isSelectable = false
            label.font = Font.metadata
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = availableWidth
            label.lineBreakMode = .byCharWrapping
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: availableWidth).isActive = true
        }
        return stack
    }

    static func sizeAboutWindow(_ window: NSWindow, to contentStack: NSStackView) {
        window.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(contentStack.fittingSize.height + Layout.windowTopInset + AboutLayout.bottomInset)
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: AboutLayout.width, height: height))
        if window.frame.size != frame.size {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height,
                                   width: frame.width, height: frame.height), display: window.isVisible)
        }
    }
}
