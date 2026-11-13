#!/bin/zsh
set -euo pipefail
project_root="${0:A:h}"
case "$#" in
  0) ;;
  1) [[ "$1" == --ci ]] || { print -u2 "Usage: $0 [--ci]"; exit 2; } ;;
  *) print -u2 "Usage: $0 [--ci]"; exit 2 ;;
esac
mkdir -p "$project_root/.build/module-cache"
"$project_root/build.sh"
swiftc "$project_root/Core/PowerPolicy.swift" "$project_root/Core/SessionCore.swift" "$project_root/Tests/CoreTests.swift" \
  -o "$project_root/.build/core-tests" -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/core-tests"
swiftc "$project_root/Core/DisplaySettings.swift" "$project_root/Tests/DisplaySettingsTests.swift" \
  -o "$project_root/.build/display-settings-tests" -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/display-settings-tests"
swiftc "$project_root/Core/DisplaySettings.swift" "$project_root/Application/GlobalDisplayHotKey.swift" \
  "$project_root/Tests/GlobalDisplayHotKeyTests.swift" -o "$project_root/.build/display-hotkey-tests" \
  -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/display-hotkey-tests"
swiftc "$project_root/System/BacklightSession.swift" "$project_root/Tests/BacklightSessionTests.swift" \
  -o "$project_root/.build/backlight-tests" -module-cache-path "$project_root/.build/module-cache" -framework IOKit
"$project_root/.build/backlight-tests"
swiftc "$project_root/Presentation/PanelPlacement.swift" "$project_root/Tests/PanelPlacementTests.swift" \
  -o "$project_root/.build/panel-tests" -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/panel-tests"
swiftc "$project_root/Application/LoginItemController.swift" "$project_root/Tests/LoginItemTests.swift" \
  -o "$project_root/.build/login-tests" -module-cache-path "$project_root/.build/module-cache" -framework ServiceManagement
"$project_root/.build/login-tests"
swiftc "$project_root/Application/AppSessionPhase.swift" "$project_root/Presentation/AppStyle.swift" "$project_root/Presentation/WakecupBrand.swift" "$project_root/Presentation/StatusIcon.swift" "$project_root/Tests/StatusIconTests.swift" \
  -o "$project_root/.build/icon-tests" -module-cache-path "$project_root/.build/module-cache" -framework AppKit
"$project_root/.build/icon-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root/Tests/FileTests.swift" \
  -o "$project_root/.build/file-tests" -module-cache-path "$project_root/.build/module-cache" -framework IOKit
"$project_root/.build/file-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root/Tests/SleepAssertionsTests.swift" \
  -o "$project_root/.build/assertion-tests" -module-cache-path "$project_root/.build/module-cache" -framework IOKit
"$project_root/.build/assertion-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root/Tests/AuthorizationTests.swift" \
  -o "$project_root/.build/authorization-tests" -module-cache-path "$project_root/.build/module-cache" -framework IOKit
"$project_root/.build/authorization-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root/Tests/HelperPolicyTests.swift" \
  -o "$project_root/.build/helper-policy-tests" -module-cache-path "$project_root/.build/module-cache" -framework IOKit
"$project_root/.build/helper-policy-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root/Tests/RecoveryTests.swift" \
  -o "$project_root/.build/recovery-tests" -module-cache-path "$project_root/.build/module-cache" -framework IOKit
"$project_root/.build/recovery-tests"
swiftc "$project_root/Core/PowerPolicy.swift" "$project_root/Core/SessionCore.swift" \
  "$project_root/System/GuardianStatusSocket.swift" "$project_root/Tests/GuardianStatusSocketTests.swift" \
  -o "$project_root/.build/guardian-status-tests" -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/guardian-status-tests"
swiftc "$project_root/Core/PowerPolicy.swift" "$project_root/Core/SessionCore.swift" \
  "$project_root/System/HelperRecoveryCompletion.swift" "$project_root/Tests/HelperRecoveryTests.swift" \
  -o "$project_root/.build/helper-recovery-tests" -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/helper-recovery-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" \
  "$project_root/Tests/SessionModelTests.swift" -o "$project_root/.build/model-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/model-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" \
  "$project_root/Tests/DisplayModeModelTests.swift" -o "$project_root/.build/display-model-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/display-model-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" \
  "$project_root/Tests/HelperStateTests.swift" -o "$project_root/.build/helper-state-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/helper-state-tests"
swiftc "$project_root/Core/AppLanguage.swift" "$project_root/Application/AppLocalization.swift" \
  "$project_root/Tests/LocalizationTests.swift" -o "$project_root/.build/localization-tests" \
  -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/localization-tests" "$project_root/Resources"
swiftc "$project_root/Core/SessionMessage.swift" "$project_root/Tests/SessionMessageTests.swift" \
  -o "$project_root/.build/message-tests" -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/message-tests"
swiftc "$project_root/Core/AppVersion.swift" "$project_root/Application/UpdateChecker.swift" \
  "$project_root/Tests/UpdateTests.swift" -o "$project_root/.build/update-tests" \
  -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/update-tests"
python3 -m unittest discover -s "$project_root/Tests" -p 'test_*.py'
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" \
  "$project_root/Tests/HelperPresentationTests.swift" -o "$project_root/.build/helper-presentation-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/helper-presentation-tests"
"$project_root/Tests/BuildMetadataTests.sh"
"$project_root/Tests/BuildVerificationTests.sh"
"$project_root/Tests/BuildPipelineTests.sh"
if [[ "${1:-}" == --ci ]]; then
  print -r -- 'Runtime enforcement is checked on a Mac with SIP enabled before publishing (see RELEASING.md).'
else
  "$project_root/Tests/HelperRuntimeTests.sh"
fi
"$project_root/.build/localization-tests" "$project_root/Resources" "$project_root/build/Wakecup.app"
swiftc "$project_root/Core/AppLanguage.swift" "$project_root/Core/SessionCore.swift" "$project_root/Core/PowerPolicy.swift" \
  "$project_root/Application/AppLocalization.swift" "$project_root/Presentation/SleepRecoveryGuide.swift" \
  "$project_root/Tests/RecoveryGuideTests.swift" -o "$project_root/.build/recovery-guide-tests" \
  -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/recovery-guide-tests" "$project_root/Resources" "$project_root/build/Wakecup.app"
"$project_root/build/Wakecup.app/Contents/MacOS/Wakecup" --self-test

swiftc "$project_root/Core/EndTimeSelection.swift" "$project_root/Presentation/StopTimeInput.swift" "$project_root/Tests/StopTimeTests.swift" \
  -o "$project_root/.build/stop-time-tests" -module-cache-path "$project_root/.build/module-cache"
"$project_root/.build/stop-time-tests"
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" \
  "$project_root/Tests/EndTimeModelTests.swift" -o "$project_root/.build/end-time-model-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/end-time-model-tests"

# Business rejections retain the selected helper; transport failures still invalidate it.
swiftc "$project_root"/Core/*.swift "$project_root"/System/*.swift "$project_root"/Application/*.swift "$project_root/.build/HelperBuildIdentity.swift" \
  "$project_root/Tests/HelperRetryTests.swift" -o "$project_root/.build/helper-retry-tests" \
  -module-cache-path "$project_root/.build/module-cache" -framework AppKit -framework IOKit -framework ServiceManagement
"$project_root/.build/helper-retry-tests"
