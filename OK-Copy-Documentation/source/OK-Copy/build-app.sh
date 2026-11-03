#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${OKCOPY_BUILD_DIR:-$ROOT/.build}"
APP="$ROOT/../OK, Copy.app"
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD/module-cache"
mkdir -p "$BUILD/tmp"
export TMPDIR="$BUILD/tmp/"
if [[ -n "${OKCOPY_TOOLCHAIN_BIN:-}" ]]; then export PATH="$OKCOPY_TOOLCHAIN_BIN:$PATH"; fi
SDK="${OKCOPY_SDK_PATH:-$(xcrun --show-sdk-path)}"
ARCH="$(uname -m)"
COMMON=(--package-path "$ROOT" --scratch-path "$BUILD/swiftpm" --cache-path "$BUILD/cache" --config-path "$BUILD/config" --security-path "$BUILD/security" --disable-sandbox)
if [[ "${OKCOPY_SKIP_TESTS:-0}" == "1" ]]; then
    printf 'XCTest suite skipped by OKCOPY_SKIP_TESTS=1; built-in safety checks still run.\n'
else
    swift test "${COMMON[@]}"
fi
swift build "${COMMON[@]}" -c release
BIN="$(swift build "${COMMON[@]}" -c release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OKCopy" "$APP/Contents/MacOS/OKCopy"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
swift "$ROOT/Tools/MakeIcon.swift" "$BUILD/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Development/OK-Copy"
for item in Sources Tests Tools Package.swift Info.plist build-app.sh README.md Engine-Notes.md "Upgrade Checklist.md" "Release Notes.md"; do
    if [[ -e "$ROOT/$item" ]]; then
        rm -rf "$APP/Contents/Resources/Development/OK-Copy/$item"
        cp -R "$ROOT/$item" "$APP/Contents/Resources/Development/OK-Copy/"
    fi
done
printf 'OK, Copy 3.7 — Verified Copying Tool\nSelf-contained Apple silicon app, macOS 14+. No Xcode is needed to run. Full source and release notes are in Resources/Development/OK-Copy.\n' > "$APP/Contents/Resources/README.txt"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/OKCopy" --self-test
swiftc -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -parse-as-library -module-cache-path "$BUILD/module-cache" -I "$BIN/Modules" \
    "$ROOT/Sources/OKCopy/AppModel.swift" "$ROOT/Tools/CheckCopyWorkflow.swift" \
    "$BIN"/IngestCore.build/*.o -o "$BUILD/CheckCopyWorkflow"
"$BUILD/CheckCopyWorkflow"
swiftc -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -parse-as-library -module-cache-path "$BUILD/module-cache" \
    "$ROOT"/Sources/IngestCore/*.swift "$ROOT/Tools/CheckFilesystem.swift" -o "$BUILD/CheckFilesystem"
"$BUILD/CheckFilesystem"
swiftc -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -parse-as-library -module-cache-path "$BUILD/module-cache" \
    "$ROOT"/Sources/IngestCore/*.swift "$ROOT/Tools/CheckImmediateCopy.swift" -o "$BUILD/CheckImmediateCopy"
"$BUILD/CheckImmediateCopy"
printf '\nBuilt: %s\n' "$APP"
