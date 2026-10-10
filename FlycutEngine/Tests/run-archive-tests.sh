#!/bin/bash
set -euo pipefail
if [[ ${1:-} == --help ]]; then
    printf '%s\n' 'Usage: bash FlycutEngine/Tests/run-archive-tests.sh' 'Builds the MRC Foundation/sqlite driver and runs isolated archive fixtures.'
    exit 0
fi
if [[ $# -ne 0 ]]; then
    printf '%s\n' 'Unexpected argument. Use --help.' >&2
    exit 2
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/flycut-archive-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Users/nowaker/Applications/Xcode-26.3.app/Contents/Developer}
xcrun clang -fno-objc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
    -mmacosx-version-min=10.13 -framework Foundation -framework CoreFoundation \
    -lsqlite3 -I "$root/FlycutEngine" "$root/FlycutEngine/FlycutArchive.m" \
    "$root/FlycutEngine/Tests/ArchiveDriver.m" -o "$build/archive-driver"
"$build/archive-driver" --help
if "$build/archive-driver"; then
    printf '%s\n' 'Driver incorrectly accepted missing fixture argument.' >&2
    exit 1
fi
"$build/archive-driver" "$root/FlycutEngine/Tests/Fixtures/archive-v1.json"
