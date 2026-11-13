#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:-$project_root/build/Wakecup.app}"
architecture=$(/usr/bin/lipo -archs "$app/Contents/MacOS/Wakecup")
fixture=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/wakecup-verification-XXXXXXXX")
trap '/bin/rm -rf "$fixture"' EXIT
reject() {
  local candidate="$1" expected="$2"
  if "$project_root/Tests/BuildMetadataTests.sh" "$candidate" "$architecture" > "$fixture/result" 2>&1; then
    print -u2 'FAIL: invalid executable passed verification'; exit 1
  fi
  /usr/bin/grep -F "$expected" "$fixture/result" >/dev/null || { cat "$fixture/result"; exit 1; }
}
mkdir -p "$fixture/damaged-app" "$fixture/damaged-helper" "$fixture/unsafe-helper"
/bin/cp -R "$app" "$fixture/damaged-app/Wakecup.app"
print -rn -- 'signature damage' >> "$fixture/damaged-app/Wakecup.app/Contents/MacOS/Wakecup"
reject "$fixture/damaged-app/Wakecup.app" 'invalid signature:'
/bin/cp -R "$app" "$fixture/damaged-helper/Wakecup.app"
print -rn -- 'signature damage' >> "$fixture/damaged-helper/Wakecup.app/Contents/Resources/Helper/local.wakecup.helper"
reject "$fixture/damaged-helper/Wakecup.app" 'invalid signature:'
/bin/cp -R "$app" "$fixture/unsafe-helper/Wakecup.app"
cat > "$fixture/unsafe.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
/usr/bin/codesign --force --options runtime --identifier local.wakecup.helper --sign - \
  --entitlements "$fixture/unsafe.plist" "$fixture/unsafe-helper/Wakecup.app/Contents/Resources/Helper/local.wakecup.helper"
/usr/bin/codesign --force --options runtime --sign - "$fixture/unsafe-helper/Wakecup.app"
reject "$fixture/unsafe-helper/Wakecup.app" 'unsafe entitlement com.apple.security.get-task-allow:'
print -r -- 'PASS: damaged app/helper signatures and unsafe helper signing entitlements are rejected'
