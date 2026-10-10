#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${FLYCUT_TEST_BUILD_DIR:-$ROOT/tmp/sync-driver}"
ARCHIVE="${FLYCUT_TEST_ARCHIVE_SOURCE:-$ROOT/FlycutEngine/FlycutArchive.m}"
mkdir -p "$BUILD"
xcrun clang -fblocks -fno-objc-arc -c "$ARCHIVE" -o "$BUILD/archive.o"
xcrun clang -fobjc-arc -fblocks -Dfsync=FlycutTestFsync -c "$ROOT/Sync/FlycutFolderSync.m" -o "$BUILD/folder.o"
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Security -lsqlite3 \
    "$ROOT/Sync/Tests/SyncDriver.m" "$ROOT/Sync/FlycutSync.m" \
    "$ROOT/Sync/FlycutServerSync.m" \
    "$BUILD/archive.o" "$BUILD/folder.o" -o "$BUILD/sync-driver"
exec "$BUILD/sync-driver" "$@"
