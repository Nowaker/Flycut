#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${FLYCUT_TEST_BUILD_DIR:-$ROOT/tmp/operator-driver}"
ARCHIVE="${FLYCUT_TEST_ARCHIVE_SOURCE:-$ROOT/FlycutEngine/FlycutArchive.m}"
mkdir -p "$BUILD"
xcrun clang -fblocks -fno-objc-arc -c "$ARCHIVE" -o "$BUILD/archive.o"
for source in FlycutSync FlycutFolderSync FlycutServerSync FlycutSyncSettingsController; do
    xcrun clang -fobjc-arc -fblocks -c "$ROOT/Sync/$source.m" -o "$BUILD/$source.o"
done
xcrun clang -fno-objc-arc -fblocks -DFLYCUT_MAC -include "$ROOT/Flycut_Prefix.pch" \
    -I"$ROOT/UI" -I"$ROOT/ShortcutRecorder" -I"$ROOT/SGHotKeysLib" \
    -framework Cocoa -framework Security -lsqlite3 "$ROOT/Sync/Tests/OperatorDriver.m" \
    "$ROOT/FlycutOperator.m" "$ROOT/FlycutEngine/FlycutStore.m" "$ROOT/FlycutEngine/FlycutClipping.m" \
    "$BUILD/archive.o" "$BUILD/FlycutSync.o" "$BUILD/FlycutFolderSync.o" \
    "$BUILD/FlycutServerSync.o" "$BUILD/FlycutSyncSettingsController.o" -o "$BUILD/operator-driver"
exec "$BUILD/operator-driver" "$@"
