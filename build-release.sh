#!/bin/zsh
# Build and validate universal signed app/ZIP/DMG packages without publishing.
set -euo pipefail
project_root="${0:A:h}"
release_dir="${1:-$project_root/build/releases}"
(( $# <= 1 )) || { print -u2 "Usage: $0 [/path/to/release-directory]"; exit 2; }
python3 "$project_root/Tools/release_metadata.py"
if [[ "${WAKECUP_REQUIRE_RELEASE_SIGNING:-0}" == 1 && "${WAKECUP_SIGNING_IDENTITY:--}" == - ]]; then
  print -u2 'Release signing is required; configure WAKECUP_SIGNING_IDENTITY'; exit 2
fi
# Release files must be usable after copying the app to /Applications.
# The signing wrapper retains its private umask for key material.
umask 022
release_dir="${release_dir:a}"
mkdir -p "$release_dir"
stage=$(/usr/bin/mktemp -d "$release_dir/.Wakecup-release-stage-XXXXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$project_root/Info.plist")
build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$project_root/Info.plist")
stem="Wakecup-$version-universal"
"$project_root/build.sh" --arch universal --output "$stage/Wakecup.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage/Wakecup.app" "$stage/$stem.zip"
/usr/bin/ditto -x -k "$stage/$stem.zip" "$stage/check"
"$project_root/Tests/BuildMetadataTests.sh" "$stage/check/Wakecup.app" universal
for executable in Contents/MacOS/Wakecup Contents/Resources/Helper/local.wakecup.helper; do
  permissions=$(/usr/bin/stat -f %OLp "$stage/check/Wakecup.app/$executable")
  (( (8#$permissions & 8#555) == 8#555 )) || {
    print -u2 "Release executable must be readable and executable by all users: $executable"
    exit 1
  }
done
mkdir -p "$stage/dmg"
/usr/bin/ditto "$stage/Wakecup.app" "$stage/dmg/Wakecup.app"
/bin/ln -s /Applications "$stage/dmg/Applications"
/usr/bin/hdiutil create -quiet -volname "Wakecup $version" -srcfolder "$stage/dmg" \
  -ov -format UDZO "$stage/$stem.dmg"
/usr/bin/hdiutil verify -quiet "$stage/$stem.dmg"

# Promote only after both architectures and both packages passed verification.
release=$(/usr/bin/mktemp -d "$release_dir/Wakecup-$version-$build-XXXXXXXX")
/bin/mv "$stage/Wakecup.app" "$stage/$stem.zip" "$stage/$stem.dmg" "$release/"
(cd "$release"; /usr/bin/shasum -a 256 *.zip *.dmg > SHA256SUMS.txt)
print -r -- "Prepared local release artifacts: $release"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  print -r -- "directory=$release" >> "$GITHUB_OUTPUT"
fi
