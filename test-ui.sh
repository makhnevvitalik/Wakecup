#!/bin/zsh
set -euo pipefail
project_root="${0:A:h}"
mkdir -p "$project_root/.build/module-cache"
"$project_root/build.sh"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/PanelLayoutTests.swift" -o "$project_root/.build/panel-layout-tests" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/panel-layout-tests"

swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/DurationInputTests.swift" -o "$project_root/.build/duration-input-tests" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/duration-input-tests"

swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/StyleContractTests.swift" -o "$project_root/.build/style-contract-tests" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/style-contract-tests" "$project_root"

fixture_app="$project_root/.build/AboutLayoutTests.app"
mkdir -p "$fixture_app/Contents/MacOS" "$fixture_app/Contents/Resources"
cp "$project_root/Info.plist" "$fixture_app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.about-layout-tests "$fixture_app/Contents/Info.plist"
cp -R "$project_root/Resources/." "$fixture_app/Contents/Resources/"
cp "$project_root/LICENSE" "$fixture_app/Contents/Resources/LICENSE.txt"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/AboutLayoutTests.swift" -o "$fixture_app/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$fixture_app/Contents/MacOS/Wakecup" en
"$fixture_app/Contents/MacOS/Wakecup" ru

# License formatting runs offscreen, without SessionModel or a helper connection.
license_fixture="$project_root/.build/LicenseDocumentTests.app"
mkdir -p "$license_fixture/Contents/MacOS" "$license_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$license_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.license-document-tests "$license_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$license_fixture/Contents/Resources/"
swiftc "$project_root/Core/AppLanguage.swift" "$project_root/Application/AppLocalization.swift" \
  "$project_root/Presentation/AppStyle.swift" "$project_root/Presentation/LicenseDocumentRenderer.swift" \
  "$project_root/Presentation/LicenseDocumentView.swift" "$project_root/Tests/LicenseDocumentTests.swift" \
  -o "$license_fixture/Contents/MacOS/Wakecup" -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit
"$license_fixture/Contents/MacOS/Wakecup" "$project_root" en
"$license_fixture/Contents/MacOS/Wakecup" "$project_root" ru

helper_fixture="$project_root/.build/HelperPresentationTests.app"
mkdir -p "$helper_fixture/Contents/MacOS" "$helper_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$helper_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.helper-presentation-tests "$helper_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$helper_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/HelperPresentationTests.swift" -o "$helper_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$helper_fixture/Contents/MacOS/Wakecup" en
"$helper_fixture/Contents/MacOS/Wakecup" ru

status_fixture="$project_root/.build/SessionStatusLayoutTests.app"
mkdir -p "$status_fixture/Contents/MacOS" "$status_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$status_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.session-layout-tests "$status_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$status_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/SessionStatusLayoutTests.swift" -o "$status_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$status_fixture/Contents/MacOS/Wakecup" en
"$status_fixture/Contents/MacOS/Wakecup" ru

row_fixture="$project_root/.build/HelperRowLayoutTests.app"
mkdir -p "$row_fixture/Contents/MacOS" "$row_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$row_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.helper-row-tests "$row_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$row_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/HelperRowLayoutTests.swift" -o "$row_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$row_fixture/Contents/MacOS/Wakecup" en
"$row_fixture/Contents/MacOS/Wakecup" ru

battery_fixture="$project_root/.build/BatteryOptionsLayoutTests.app"
mkdir -p "$battery_fixture/Contents/MacOS" "$battery_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$battery_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.battery-layout-tests "$battery_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$battery_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/BatteryOptionsLayoutTests.swift" -o "$battery_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$battery_fixture/Contents/MacOS/Wakecup" en
"$battery_fixture/Contents/MacOS/Wakecup" ru

helper_dialog_fixture="$project_root/.build/HelperDialogLayoutTests.app"
mkdir -p "$helper_dialog_fixture/Contents/MacOS" "$helper_dialog_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$helper_dialog_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.helper-dialog-tests "$helper_dialog_fixture/Contents/Info.plist"
cp -R "$project_root/build/Wakecup.app/Contents/Resources/." "$helper_dialog_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" \
  "$project_root/Presentation/AppStyle.swift" "$project_root/Presentation/HelperSettingsDialog.swift" \
  "$project_root/Presentation/HelperInteraction.swift" "$project_root/Presentation/HelperPresentation.swift" \
  "$project_root/Tests/HelperDialogLayoutTests.swift" -o "$helper_dialog_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework AppKit -framework IOKit -framework ServiceManagement
"$helper_dialog_fixture/Contents/MacOS/Wakecup" en
"$helper_dialog_fixture/Contents/MacOS/Wakecup" ru

# This fixture renders offscreen and uses fake system operations.
display_fixture="$project_root/.build/ActiveDisplayControlTests.app"
mkdir -p "$display_fixture/Contents/MacOS" "$display_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$display_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.active-display-tests "$display_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$display_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/ActiveDisplayControlLayoutTests.swift" -o "$display_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$display_fixture/Contents/MacOS/Wakecup" en
"$display_fixture/Contents/MacOS/Wakecup" ru

# Unified settings render offscreen with isolated defaults and fake system operations.
unified_fixture="$project_root/.build/UnifiedSettingsTests.app"
mkdir -p "$unified_fixture/Contents/MacOS" "$unified_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$unified_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.unified-settings-tests "$unified_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$unified_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/UnifiedSettingsLayoutTests.swift" -o "$unified_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$unified_fixture/Contents/MacOS/Wakecup" en
"$unified_fixture/Contents/MacOS/Wakecup" ru

# Local recorder only: no real registration, keys, brightness or visible windows.
shortcut_fixture="$project_root/.build/DisplayShortcutEditorTests.app"
mkdir -p "$shortcut_fixture/Contents/MacOS" "$shortcut_fixture/Contents/Resources"
cp "$project_root/Info.plist" "$shortcut_fixture/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string local.wakecup.display-shortcut-tests "$shortcut_fixture/Contents/Info.plist"
cp -R "$project_root/Resources/." "$shortcut_fixture/Contents/Resources/"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift \
  "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" "$project_root"/Presentation/*.swift \
  "$project_root/Tests/DisplayShortcutEditorTests.swift" -o "$shortcut_fixture/Contents/MacOS/Wakecup" \
  -module-cache-path "$project_root/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement
"$shortcut_fixture/Contents/MacOS/Wakecup" en
"$shortcut_fixture/Contents/MacOS/Wakecup" ru

# Native battery scale only; no session, power or helper operations.
swiftc "$project_root/Core/AppLanguage.swift" "$project_root/Core/PowerPolicy.swift" "$project_root/Application/AppLocalization.swift" \
  "$project_root/Presentation/AppStyle.swift" "$project_root/Presentation/BatteryLevelControl.swift" \
  "$project_root/Tests/BatteryLevelControlTests.swift" -o "$project_root/.build/battery-level-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework SwiftUI
"$project_root/.build/battery-level-tests"

# Enlarged native date selection: offscreen and isolated from system settings.
swiftc "$project_root/Core/AppLanguage.swift" "$project_root/Core/EndTimeSelection.swift" "$project_root/Application/AppLocalization.swift" \
  "$project_root/Presentation/AppStyle.swift" "$project_root/Presentation/CalendarDayPicker.swift" \
  "$project_root/Tests/CalendarDayPickerTests.swift" -o "$project_root/.build/calendar-day-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework SwiftUI
"$project_root/.build/calendar-day-tests"

# Midnight entry never changes the selected calendar day; native controls only.
swiftc "$project_root/Core/AppLanguage.swift" "$project_root/Core/EndTimeSelection.swift" \
  "$project_root/Application/AppLocalization.swift" "$project_root/Presentation/AppStyle.swift" \
  "$project_root/Presentation/StopTimeInput.swift" "$project_root/Presentation/StopTimeField.swift" \
  "$project_root/Tests/StopTimeDayTests.swift" -o "$project_root/.build/stop-time-day-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework SwiftUI
"$project_root/.build/stop-time-day-tests"
