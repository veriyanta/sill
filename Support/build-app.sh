#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ $(uname -m) != arm64 ]]; then
    print -u2 'Run the build with an Apple silicon Swift toolchain.'
    exit 1
fi
args=(-c release)
if [[ -n ${SILL_BUILD_DIR:-} ]]; then args+=(--scratch-path "$SILL_BUILD_DIR"); fi
if [[ -n ${SILL_BUILD_SYSTEM:-} ]]; then args+=(--build-system "$SILL_BUILD_SYSTEM"); fi
if [[ ${SILL_NESTED_SANDBOX:-1} == 0 ]]; then args+=(--disable-sandbox); fi
swift build "${args[@]}"
bin=$(swift build "${args[@]}" --show-bin-path)
app="${1:-$PWD/.build/Sill.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Support/Info.plist "$app/Contents/Info.plist"
cp "$bin/Sill" "$app/Contents/MacOS/Sill"
cp Support/Sill.icns "$app/Contents/Resources/Sill.icns"
case "${SILL_APP_SANDBOX:-1}" in
    1) codesign --force --sign - --entitlements Support/Sandbox.entitlements "$app" ;;
    0) codesign --force --sign - "$app" ;;
    *) print -u2 'Set SILL_APP_SANDBOX to 0 or 1.'; exit 1 ;;
esac
codesign --verify --strict "$app"
print "$app"
