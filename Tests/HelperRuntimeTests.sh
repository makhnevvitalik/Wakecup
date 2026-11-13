#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:-$project_root/build/Wakecup.app}"
[[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/Wakecup")" == "$(/usr/bin/uname -m)" ]] || {
  print -u2 'Runtime tests require an app built for this Mac architecture'; exit 2
}
"$app/Contents/MacOS/Wakecup" --helper-self-test
fixture=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/wakecup-injection-XXXXXXXX")
trap '/bin/rm -rf "$fixture"' EXIT
cat > "$fixture/inject.c" <<'SOURCE'
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void injected(void) {
    const char *path = getenv("WAKECUP_INJECTION_MARKER");
    if (path) { FILE *f = fopen(path, "w"); if (f) { fputs("injected", f); fclose(f); } }
}
SOURCE
/usr/bin/clang -dynamiclib "$fixture/inject.c" -o "$fixture/inject.dylib"
/usr/bin/env DYLD_INSERT_LIBRARIES="$fixture/inject.dylib" WAKECUP_INJECTION_MARKER="$fixture/marker" \
  "$app/Contents/MacOS/Wakecup" --helper-self-test
[[ ! -e "$fixture/marker" ]] || { print -u2 'Hardened Runtime allowed GUI library injection'; exit 1; }
# No helper operation is requested: this only tests process startup rejection,
# never daemon/install/uninstall or the accepted system helper installation.
if /usr/bin/env DYLD_INSERT_LIBRARIES="$fixture/inject.dylib" WAKECUP_INJECTION_MARKER="$fixture/marker" \
  "$app/Contents/Resources/Helper/local.wakecup.helper" > "$fixture/helper-output" 2>&1; then
  print -u2 'Helper unexpectedly accepted no operation'; exit 1
fi
[[ ! -e "$fixture/marker" ]] || { print -u2 'Hardened Runtime allowed helper library injection'; exit 1; }
print -r -- 'PASS: Hardened Runtime rejects DYLD library injection into the approved GUI and bundled helper'
