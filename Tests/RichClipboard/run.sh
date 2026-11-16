#!/bin/zsh
# Builds and runs the rich clipboard tests against the engine sources. Usage: Tests/RichClipboard/run.sh [slack-custom.bin]
# The fixtures are copies of opencode-tools' _lib/rich-clipboard/fixtures; copy them again when they change there.
set -e
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Applications/Xcode-26.3.app/Contents/Developer}
mkdir -p tmp
xcrun clang -fno-objc-arc -Wall -Wno-deprecated-declarations -Wno-nullability-completeness -I. -IFlycutEngine \
	-framework Cocoa -framework Carbon -framework ApplicationServices -o tmp/rich-clipboard-qa \
	Tests/RichClipboard/rich-clipboard-qa.m FlycutEngine/FlycutRichClipboard.m FlycutPasteboard.m \
	FlycutEngine/FlycutClipping.m FlycutEngine/FlycutBlobStore.m
tmp/rich-clipboard-qa Tests/RichClipboard/fixtures "$@"
