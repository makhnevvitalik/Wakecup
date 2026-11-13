#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app_path="${1:-$project_root/build/Wakecup.app}"
expected_arch="${2:-$(/usr/bin/uname -m)}"
expected_minimum="14.0"
plist_path="$app_path/Contents/Info.plist"

fail() {
  print -u2 -r -- "Build metadata test failed: $1"
  exit 1
}

/usr/bin/plutil -lint "$plist_path" >/dev/null
minimum=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$plist_path")
[[ "$minimum" == "$expected_minimum" ]] || fail "Info.plist minimum is $minimum, expected $expected_minimum"
executable=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist_path")
helper="$app_path/Contents/Resources/Helper/local.wakecup.helper"
for binary in "$app_path/Contents/MacOS/$executable" "$helper"; do
  [[ -x "$binary" ]] || fail "missing executable: $binary"
  architecture=$(/usr/bin/lipo -archs "$binary")
  [[ "$architecture" == "$expected_arch" ]] || fail "Mach-O architecture is $architecture, expected $expected_arch: $binary"
  minimum_versions=("${(@f)$(/usr/bin/otool -arch all -l "$binary" | /usr/bin/awk '
    $1 == "cmd" { build_version = ($2 == "LC_BUILD_VERSION") }
    build_version && $1 == "minos" { print $2 }
  ')}")
  [[ ${#minimum_versions} == 1 && -n "${minimum_versions[1]}" ]] || fail "executable has no single LC_BUILD_VERSION minimum: $binary"
  [[ "${minimum_versions[1]}" == "$minimum" ]] || fail "Mach-O minimum is ${minimum_versions[1]}, Info.plist declares $minimum: $binary"
  /usr/bin/codesign --verify --strict "$binary" || fail "invalid signature: $binary"
  signature=$(/usr/bin/codesign -dvvv "$binary" 2>&1)
  [[ "$signature" == *'flags='*'runtime'* ]] || fail "Hardened Runtime is missing: $binary"
  entitlements=$(/usr/bin/codesign -d --entitlements :- "$binary" 2>/dev/null)
  if [[ -n "$entitlements" ]]; then
    for key in com.apple.security.get-task-allow com.apple.security.cs.allow-dyld-environment-variables \
      com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-unsigned-executable-memory; do
      key_path=${key//./\\.}
      enabled=$(print -rn -- "$entitlements" | /usr/bin/plutil -extract "$key_path" raw -o - - 2>/dev/null || true)
      [[ "$enabled" != true ]] || fail "unsafe entitlement $key: $binary"
    done
  fi
done
[[ "$(/usr/bin/codesign -dvvv "$helper" 2>&1 | /usr/bin/awk -F= '$1 == "Identifier" {print $2}')" == local.wakecup.helper ]] || fail 'unexpected helper signing identity'
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist_path")" == local.wakecup ]] || fail 'unexpected app bundle identity'
[[ "$(/usr/bin/codesign -dvvv "$app_path" 2>&1 | /usr/bin/awk -F= '$1 == "Identifier" {print $2}')" == local.wakecup ]] || fail 'unexpected app signing identity'
# Cross-architecture builds cannot run here. Confirm that their exact signed
# helper hashes are embedded in their corresponding GUI executable as well.
helper_sha=$(/usr/bin/shasum -a 256 "$helper" | /usr/bin/awk '{print $1}')
helper_cdhash=$(/usr/bin/codesign -dvvv "$helper" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
[[ ${#helper_sha} == 64 && ${#helper_cdhash} == 40 ]] || fail 'invalid helper hashes'
/usr/bin/strings "$app_path/Contents/MacOS/$executable" | /usr/bin/awk -v sha="$helper_sha" -v cdhash="$helper_cdhash" '
  $0 == sha { found_sha = 1 }
  $0 == cdhash { found_cdhash = 1 }
  END { exit !(found_sha && found_cdhash) }
' || fail 'GUI does not contain the matching signed helper pins'
/usr/bin/codesign --verify --strict --deep "$app_path" || fail 'invalid bundle signature'
icon_name=$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$plist_path")
[[ -s "$app_path/Contents/Resources/$icon_name.icns" ]] || fail "declared application icon is missing"
[[ ! -e "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.txt" ]] || fail "obsolete third-party notice remains bundled"
for language in en ru; do
  [[ -s "$app_path/Contents/Resources/RecoveryGuide.$language.txt" ]] || fail "missing $language recovery guide"
done
print -r -- "Build metadata tests passed (app and helper: $expected_arch, macOS $minimum, strict signatures, Hardened Runtime, matching helper pins)"
