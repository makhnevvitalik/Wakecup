#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
fixture=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/wakecup-build-tests-XXXXXXXX")
trap '/bin/rm -rf "$fixture"' EXIT
for entry in App Application Core Helper Presentation Resources System Tests Info.plist LICENSE build.sh; do
  /bin/cp -R "$project_root/$entry" "$fixture/$entry"
done
mkdir -p "$fixture/build/Wakecup.app/Contents/Resources"
print -r -- old-artifact > "$fixture/build/Wakecup.app/Contents/Resources/stale-resource.txt"
"$fixture/build.sh" > "$fixture/success.log" 2>&1 || { cat "$fixture/success.log"; exit 1; }
[[ ! -e "$fixture/build/Wakecup.app/Contents/Resources/stale-resource.txt" ]] || {
  print -u2 'FAIL: a removed resource survived the clean build'; exit 1
}
backups=("$fixture/build"/.Wakecup-backup-*(N))
[[ ${#backups} == 1 && -f "${backups[1]}/Wakecup.app/Contents/Resources/stale-resource.txt" ]] || {
  print -u2 'FAIL: previous local app was not retained'; exit 1
}
# Hash the complete accepted bundle, including resources, helper and signature.
bundle_hash() {
  (cd "$fixture/build/Wakecup.app"; /usr/bin/find . -type f -exec /usr/bin/shasum -a 256 '{}' + | /usr/bin/sort) |
    /usr/bin/shasum -a 256
}
before=$(bundle_hash)
# Make helper compilation succeed with different bytes, then fail GUI compilation.
print '\nprint("controlled build failure fixture")' >> "$fixture/Helper/main.swift"
print '\nthis is deliberately invalid Swift' >> "$fixture/App/main.swift"
if "$fixture/build.sh" > "$fixture/failure.log" 2>&1; then
  print -u2 'FAIL: deliberately invalid source unexpectedly built'; exit 1
fi
[[ "$(bundle_hash)" == "$before" ]] || { print -u2 'FAIL: failed build changed the previous app'; exit 1; }
stages=("$fixture/build"/.Wakecup-stage-*(N))
[[ ${#stages} == 0 ]] || { print -u2 'FAIL: failed build left temporary staging files'; exit 1; }
# Fail after app promotion and after the helper identity has been updated. A
# test-local copy tool shim injects only this I/O failure; real compilation runs.
/bin/cp "$project_root/App/main.swift" "$fixture/App/main.swift"
sidecar_hash() {
  /usr/bin/shasum -a 256 "$fixture/.build/HelperBuildIdentity.swift" "$fixture/build"/RecoveryGuide*.txt
}
sidecars_before=$(sidecar_hash)
mkdir -p "$fixture/tools"
cat > "$fixture/tools/cp" <<'COPY'
#!/bin/zsh
if [[ "${@[-1]}" == */build/RecoveryGuide.en.txt ]]; then
  print -u2 'Controlled sidecar promotion failure'; exit 75
fi
exec /bin/cp "$@"
COPY
/bin/chmod 755 "$fixture/tools/cp"
if PATH="$fixture/tools:$PATH" "$fixture/build.sh" > "$fixture/promotion-failure.log" 2>&1; then
  print -u2 'FAIL: controlled promotion failure unexpectedly succeeded'; exit 1
fi
/usr/bin/grep -F 'Controlled sidecar promotion failure' "$fixture/promotion-failure.log" >/dev/null || {
  cat "$fixture/promotion-failure.log"; exit 1
}
[[ "$(bundle_hash)" == "$before" ]] || { print -u2 'FAIL: promotion failure changed the previous app'; exit 1; }
[[ "$(sidecar_hash)" == "$sidecars_before" ]] || { print -u2 'FAIL: promotion failure changed the previous sidecars'; exit 1; }
stages=("$fixture/build"/.Wakecup-stage-*(N))
backups=("$fixture/build"/.Wakecup-backup-*(N))
[[ ${#stages} == 0 && ${#backups} == 1 ]] || { print -u2 'FAIL: promotion failure left temporary artifacts'; exit 1; }
print -r -- 'PASS: clean resources, retained previous app, compiler/promotion failures preserve accepted app and sidecars, temporary stages removed'
