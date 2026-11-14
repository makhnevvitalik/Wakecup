# Wakecup

<img src="Resources/Artwork/WakecupIcon.png" width="96" alt="Wakecup icon">

**AI works. Your Mac stays wide awake.** · **ИИ работает — Mac не дремлет.**

Wakecup keeps your Mac awake while your AI agent works. You can set a stop time and turn off the built-in display’s backlight to save battery.

[Download the latest release](https://github.com/makhnevvitalik/Wakecup/releases/latest)

## Contents

- [English](#english)
  - [Features](#features)
  - [Install and start](#install-and-start)
  - [Set when to stop](#set-when-to-stop)
  - [Display backlight](#display-backlight)
  - [Battery and closed lid](#battery-and-closed-lid)
  - [Settings and updates](#settings-and-updates)
  - [CLI and MCP](#cli-and-mcp)
  - [If your Mac does not sleep after Wakecup is off](#if-your-mac-does-not-sleep-after-wakecup-is-off)
  - [Privacy and license](#privacy-and-license)
- [Русский](#русский)
  - [Возможности](#возможности)
  - [Установка и первый запуск](#установка-и-первый-запуск)
  - [Когда остановить](#когда-остановить)
  - [Подсветка экрана](#подсветка-экрана)
  - [Аккумулятор и закрытая крышка](#аккумулятор-и-закрытая-крышка)
  - [Настройки и обновления](#настройки-и-обновления)
  - [CLI и MCP](#cli-и-mcp)
  - [Если Wakecup выключен, а Mac не засыпает](#если-wakecup-выключен-а-mac-не-засыпает)
  - [Приватность и лицензия](#приватность-и-лицензия)

## English

### Features

- Keep your Mac awake for 1, 3 or 5 hours, until a chosen time today or in the next 30 calendar days, or until you stop it.
- Turn off the built-in display’s backlight to save battery, keep the display on, or let macOS manage it.
- Optionally keep the Mac awake with the lid closed.
- Choose whether to continue on battery and stop at a selected charge level from 10% to 90%.
- Install an optional helper to enable closed-lid mode without entering an administrator password every time.
- English and Russian interface, launch at login and GitHub update checks.

### Install and start

Wakecup requires **macOS 14 or later**.

1. Download the universal DMG from the [latest release](https://github.com/makhnevvitalik/Wakecup/releases/latest). It works on Apple Silicon and Intel.
2. Open the DMG and drag **Wakecup.app** to **Applications**.
3. Open Wakecup from Applications or Spotlight to show its window. The cup icon in the menu bar opens the same controls in a panel. With **Open at Login** enabled, Wakecup starts in the background.
4. Leave the lid open, turn off **Keep awake with lid closed**, choose **1 hour**, and click **Start**. Click **Stop** to end the timer early.

#### First-launch notes

- You can also download a ZIP archive, unpack it, and move Wakecup to **Applications**.
- macOS may block Wakecup the first time you open it. If that happens, go to **System Settings → Privacy & Security**, find the message about Wakecup, and choose **Open Anyway** if available.
- The cup icon is outlined when Wakecup is off and filled when it is active. If a warning appears on the icon, see [how to restore sleep](#if-your-mac-does-not-sleep-after-wakecup-is-off).

### Set when to stop

- **1 hour**, **3 hours**, **5 hours** set an end time relative to now. If you pick **1 hour** at 23:30, Wakecup stops at 00:30 tomorrow.
- To stop at a specific time, choose **Today**, **Tomorrow** or **Choose date…**, then enter the time in **Stop at**. You can type `0930` for `09:30`. If the time has already passed, choose **Tomorrow** to keep the same time on the next day.
- **∞** or **Indefinitely** runs until you stop it manually or your power settings cause Wakecup to stop.

While Wakecup is active, changes to the end time, power, lid or display settings take effect when you click **Apply** at the bottom. Use **Cancel** to discard the edits. To change the closed-lid option, open the lid first. If you leave the timer alone, the end time stays the same even if macOS asks for administrator permission.

### Display backlight

Quick example. While your AI agent is working, leave the lid open and turn off **Keep awake with lid closed**. Choose **3 hours** and **Backlight off**, then save a **Restore brightness** shortcut if prompted. If you’re on battery, enable **Keep awake on battery** and set the stop threshold below the current charge. Click **Start**.

| Mode | What happens |
| --- | --- |
| **Follow macOS settings** | The display can turn off according to the macOS timer while Wakecup keeps the Mac awake. |
| **Keep on** | The display stays on while Wakecup is active. |
| **Backlight off** | A supported built-in display stays on at zero brightness after a 10-second countdown. |

To use **Backlight off** for the first time, choose the mode and save a shortcut in the **Restore brightness** dialog. Use F1–F20 with at least one of Shift, Control, Option or Command. You can change it in the **Restore brightness** row while the backlight is on.

Once the backlight goes dark, press the shortcut to restore the previous brightness and display mode. The brightness-up key also brings back the backlight if you forget the shortcut. Wakecup restores brightness when you stop it or if the app exits unexpectedly. Wakecup leaves macOS lock-screen settings alone.

### Battery and closed lid

**Keep awake on battery** permits use without a charger. If it is off, you must connect a charger to start; disconnecting it stops Wakecup. With battery use enabled, the selected stop threshold applies while running on battery, including with the lid closed. A connected charger is not subject to that threshold.

To work with the lid closed, turn on **Keep awake with lid closed** with the lid open, and click **Start**. Confirm the macOS prompt if it appears, then wait for Wakecup to show that it is active before closing the lid. Wakecup needs administrator permission to change a system sleep setting temporarily.

If you use this mode often, stop Wakecup and click **Install** in the **Helper** row below the lid option. Confirm the macOS prompt. The helper gets permission during installation and never stores your password. Use **Configure…** in the same row to manage the helper. Installation, update and removal still require administrator permission.

After updating Wakecup, update the helper if prompted. Use **Configure…** to return to password prompts or remove the helper. Stop Wakecup before updating or removing the app or helper.

Keep ventilation clear when using closed-lid mode. Wakecup requests that macOS stay awake; it cannot guarantee that every task will continue through a system shutdown or other system-enforced interruption.

### Settings and updates

Open the gear menu to change **Language**, enable **Open at Login**, or manage the icon and remaining time in the menu bar. **Show in Menu Bar** is on by default. To restore the hidden icon, open Wakecup from **Applications** or Spotlight, then enable **Show in Menu Bar** in the gear menu. Wakecup checks GitHub in the background at launch. When Wakecup is idle, the **Update available** link below the app name opens the new release. While Wakecup is active, that line shows the session status. You can also check manually in **About… → Check for Updates**.

### CLI and MCP

The command line and MCP both control the Wakecup timer shown in the menu bar. Open Wakecup, or start it in the background with the CLI's `start` command.

```sh
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli status
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli start 3h --lid off
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli extend 30m
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli --help
```

Set a new end time at least 10 seconds ahead. To extend or shorten a timer, specify at least 10 seconds. The CLI returns JSON. When a command returns `pending`, check `status` for the result. If a command returns `partiallyApplied`, its timer or power changes may already be active. Retry only the display change. macOS can request administrator approval for closed-lid mode or helper changes.

#### Connect Wakecup to Codex

1. Open Wakecup from **Applications** and select **MCP → Enable MCP** in the gear menu.
2. Run this command in Terminal on the same Mac.

   ```sh
   codex mcp add wakecup -- /Applications/Wakecup.app/Contents/MacOS/Wakecup --cli mcp
   ```

3. Restart Codex and ask “What’s the Wakecup status?” Keep Wakecup running while using MCP.

You can also add Wakecup directly to the Codex configuration file, `~/.codex/config.toml`.

```toml
[mcp_servers.wakecup]
command = "/Applications/Wakecup.app/Contents/MacOS/Wakecup"
args = ["--cli", "mcp"]
```

Wakecup must be running with **Enable MCP** selected for the server to start. An existing client can reconnect after a brief Wakecup restart. If a command loses its reply, check status before retrying. Turning MCP off disconnects clients. After turning it back on, reconnect the client. The timer and CLI stay available.

### If your Mac does not sleep after Wakecup is off

Click **Restore Normal Sleep** if Wakecup shows that button. The troubleshooting link at the bottom of the panel opens a guide with manual steps. Wakecup normally restores the sleep setting even if the app exits unexpectedly.

If Wakecup cannot open or automatic recovery fails, quit Wakecup and any other apps that keep your Mac awake. In Terminal, run `/usr/bin/pmset -g` and look for `SleepDisabled`. If the value is `0` or the line is absent, check what is keeping the Mac awake with `/usr/bin/pmset -g assertions`.

If `SleepDisabled` remains `1` and you want to remove the system-wide sleep block, run:

```sh
sudo /usr/bin/pmset disablesleep 0
```

This clears the sleep block regardless of which app enabled it. Run `/usr/bin/pmset -g` again to confirm the result. The built app includes `RecoveryGuide.en.txt` and `RecoveryGuide.ru.txt` under `Contents/Resources`.

### Privacy and license

No analytics or external accounts. Automatic and manual update checks contact GitHub to read the latest public release. Wakecup does not require Accessibility or Input Monitoring access.

The original Wakecup source code, documentation and artwork are available under the [MIT License with the Commons Clause License Condition v1.0](LICENSE). You can use, modify and share Wakecup for free. The license prohibits selling Wakecup or a product or service whose value comes largely from it. Apple frameworks and system interface symbols remain under Apple’s terms. Wakecup bundles no third-party libraries or data.

## Русский

Wakecup не даёт Mac уснуть, пока ИИ-агент выполняет задачу. Можно задать время остановки и погасить подсветку встроенного экрана, чтобы экономить заряд.

[Скачать последнюю версию](https://github.com/makhnevvitalik/Wakecup/releases/latest)

### Возможности

- Не давать Mac уснуть 1, 3 или 5 часов, до выбранного времени сегодня или в ближайшие 30 календарных дней либо до ручной остановки.
- Гасить подсветку встроенного экрана для экономии заряда, оставлять экран включённым или передавать управление macOS.
- При необходимости работать с закрытой крышкой.
- Разрешать работу от аккумулятора и останавливать Wakecup при выбранном заряде от 10% до 90%.
- Установить необязательного помощника, чтобы не вводить пароль администратора при каждом включении режима с закрытой крышкой.
- Русский и английский интерфейс, запуск при входе и проверка обновлений на GitHub.

### Установка и первый запуск

Wakecup требует **macOS 14 или новее**.

1. Скачайте универсальный DMG из [последнего релиза](https://github.com/makhnevvitalik/Wakecup/releases/latest). Он подходит для Apple Silicon и Intel.
2. Откройте DMG и перетащите **Wakecup.app** в папку **Программы**.
3. Откройте Wakecup из папки «Программы» или через Spotlight, чтобы показать его окно. Значок кружки в строке меню открывает панель с теми же настройками. При включённом автозапуске Wakecup запускается в фоне.
4. Оставьте крышку открытой, отключите **Не засыпать с закрытой крышкой**, выберите **1 час** и нажмите **Включить**. Чтобы закончить раньше, нажмите **Остановить**.

#### Первый запуск

- Можно также скачать ZIP-архив, распаковать его и перенести Wakecup в папку **Программы**.
- При первом запуске macOS может заблокировать Wakecup. Если это произошло, откройте **Системные настройки → Конфиденциальность и безопасность**, найдите сообщение о Wakecup и нажмите **Всё равно открыть**, если кнопка доступна.
- Когда Wakecup выключен, в строке меню виден контур кружки. Когда режим активен, кружка заполнена. Если на значке появилось предупреждение, см. [как восстановить сон](#если-wakecup-выключен-а-mac-не-засыпает).

### Когда остановить

- **1 час**, **3 часа**, **5 часов** задают время окончания от текущего момента. Например, если в 23:30 выбрать **1 час**, Wakecup остановится завтра в 00:30.
- Чтобы остановить Wakecup к определённому времени, выберите **Сегодня**, **Завтра** или **Выбрать дату…**, а затем введите время в поле **Остановить в**. Можно набрать `0930`, чтобы получить `09:30`. Если время уже прошло, кнопка **Завтра** перенесёт его на следующий день.
- **∞** или **Бессрочно** оставляет Wakecup включённым до ручной остановки или пока это позволяют настройки питания.

Пока Wakecup активен, изменения времени, питания, режима крышки или подсветки вступают в силу после нажатия **Применить** внизу панели. **Отменить** сбрасывает правки. Чтобы изменить режим крышки, сначала откройте её. Если вы не меняли таймер, время окончания сохранится, даже если macOS запросит разрешение администратора.

### Подсветка экрана

Простой пример. Пока ИИ-агент выполняет задачу, оставьте крышку открытой и отключите **Не засыпать с закрытой крышкой**. Выберите **3 часа** и **Без подсветки**. Если Wakecup предложит, сохраните сочетание **Вернуть яркость**. Если Mac работает от аккумулятора, включите **Не засыпать без зарядки** и задайте порог остановки ниже текущего заряда. Нажмите **Включить**.

| Режим | Что происходит |
| --- | --- |
| **Как в настройках macOS** | Экран может погаснуть по системному таймеру, а Mac продолжит работать. |
| **Не выключать** | Экран остаётся включённым, пока работает Wakecup. |
| **Без подсветки** | Через 10 секунд яркость поддерживаемого встроенного экрана падает до нуля, а сам экран остаётся включённым. |

При первом выборе **Без подсветки** Wakecup предложит настроить сочетание **Вернуть яркость**. Назначьте F1–F20 с одним или несколькими модификаторами Shift, Control, Option или Command. Пока подсветка включена, сочетание можно изменить в строке **Вернуть яркость**.

Когда подсветка погаснет, нажмите сочетание, чтобы вернуть прежнюю яркость и режим экрана. Если забыли сочетание, включите подсветку клавишей увеличения яркости. Wakecup восстанавливает яркость при остановке режима и при неожиданном завершении приложения. Настройки блокировки экрана macOS Wakecup оставляет прежними.

### Аккумулятор и закрытая крышка

**Не засыпать без зарядки** разрешает работу от аккумулятора. Если настройка выключена, для включения нужна зарядка; при её отключении Wakecup остановится. Если работа от аккумулятора разрешена, выбранный порог остановки действует при питании от аккумулятора, в том числе с закрытой крышкой. При подключённой зарядке этот порог не применяется.

Чтобы работать с закрытой крышкой, при открытой крышке включите **Не засыпать с закрытой крышкой**, нажмите **Включить** и подтвердите запрос macOS, если он появится. Закрывайте крышку, когда Wakecup покажет, что режим активен. Разрешение администратора нужно для временного изменения системной настройки сна.

Если пользуетесь этим режимом часто, остановите Wakecup, нажмите **Установить** в строке **Помощник** и подтвердите запрос macOS. Помощник получает права при установке и не хранит пароль. Управлять им можно через **Настроить…** в той же строке. Установка, обновление и удаление по-прежнему требуют разрешения администратора.

После обновления Wakecup обновите помощника, если приложение предложит это сделать. Через **Настроить…** можно вернуть запрос пароля или удалить помощника. Перед обновлением или удалением приложения или помощника остановите Wakecup.

При работе с закрытой крышкой оставляйте вентиляцию открытой. Wakecup просит macOS не засыпать, но не гарантирует продолжение задач при выключении компьютера или других принудительных остановках системы.

### Настройки и обновления

В меню шестерёнки можно выбрать **Язык**, включить **Запускать при входе**, настроить значок и остаток времени в строке меню. Пункт **Показывать в строке меню** включён по умолчанию. Чтобы вернуть скрытый значок, откройте Wakecup из папки **«Программы»** или через Spotlight, затем включите **Показывать в строке меню** в меню шестерёнки. При запуске Wakecup проверяет GitHub в фоне. Если вышла новая версия, под названием появится ссылка **Доступно обновление**. Пока Wakecup активен, на этой строке виден статус работы. Проверить обновления вручную можно через **О приложении… → Проверить обновления**.

### CLI и MCP

CLI и MCP управляют тем же таймером, что и панель Wakecup. Откройте приложение или запустите его в фоне командой CLI `start`.

```sh
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli status
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli start 3h --lid off
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli extend 30m
/Applications/Wakecup.app/Contents/MacOS/Wakecup --cli --help
```

До нового времени остановки должно оставаться не меньше 10 секунд. Продлить или сократить таймер можно минимум на 10 секунд. CLI возвращает результат в JSON. Если команда вернула `pending`, проверьте результат через `status`. При ответе `partiallyApplied` изменения таймера или питания могли уже вступить в силу. Повторите только изменение подсветки. Для работы с закрытой крышкой и управления помощником macOS может запросить разрешение администратора.

#### Подключение к Codex

1. Откройте Wakecup из папки «Программы» и выберите **MCP → Включить MCP** в меню шестерёнки.
2. Выполните команду в Терминале на том же Mac.

   ```sh
   codex mcp add wakecup -- /Applications/Wakecup.app/Contents/MacOS/Wakecup --cli mcp
   ```

3. Перезапустите Codex и спросите «Какой сейчас статус Wakecup?». Для работы MCP оставьте Wakecup запущенным.

Если удобнее настроить подключение вручную, добавьте [блок конфигурации](#connect-wakecup-to-codex) в файл `~/.codex/config.toml`.

Сервер запускается, когда Wakecup открыт и MCP включён. После короткого перезапуска Wakecup существующее подключение восстанавливается. Если ответ на команду потерялся, проверьте статус перед повтором. Если выключить MCP в меню, подключение закроется. После повторного включения подключите клиент снова. Таймер и CLI останутся доступны.

### Если Wakecup выключен, а Mac не засыпает

Если Wakecup показывает кнопку **Восстановить обычный сон**, нажмите её. Ссылка внизу панели открывает инструкцию по ручному восстановлению. Wakecup обычно восстанавливает сон даже при неожиданном завершении приложения.

Если Wakecup не открывается или автоматическое восстановление не помогло, завершите Wakecup и другие приложения, которые удерживают Mac от сна. В Терминале выполните `/usr/bin/pmset -g` и найдите `SleepDisabled`. Если значение равно `0` или такой строки нет, посмотрите, что мешает сну, с помощью `/usr/bin/pmset -g assertions`.

Если `SleepDisabled` остаётся равным `1` и вы хотите снять общий запрет сна, выполните:

```sh
sudo /usr/bin/pmset disablesleep 0
```

Команда снимает запрет сна, даже если его включила другая программа. Повторите `/usr/bin/pmset -g`, чтобы проверить результат. Текстовые инструкции `RecoveryGuide.ru.txt` и `RecoveryGuide.en.txt` лежат внутри приложения в `Contents/Resources`.

### Приватность и лицензия

Аналитики и внешних аккаунтов нет. При автоматической и ручной проверке обновлений приложение обращается к GitHub за последним публичным релизом. Доступ к Универсальному доступу и Мониторингу ввода не требуется.

Исходный код, документация и оригинальная графика Wakecup доступны по [лицензии MIT с условием Commons Clause License Condition v1.0](LICENSE). Wakecup можно использовать, изменять и распространять бесплатно. Лицензия запрещает продавать Wakecup, а также продукты и услуги, ценность которых в значительной степени основана на нём. На системные компоненты и символы интерфейса распространяются условия Apple. В Wakecup нет сторонних библиотек и наборов данных.
