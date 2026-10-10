#!/bin/bash
# English.lproj/MainMenu.nib is a legacy nib wrapper: the build ships its precompiled
# keyedobjects*.nib as-is and never recompiles designable.nib. After editing
# designable.nib by hand, run this to regenerate the compiled copies from it.
set -euo pipefail

cd "$(dirname "$0")"
nib=English.lproj/MainMenu.nib
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$nib/designable.nib" "$work/MainMenu.xib"
xcrun ibtool --errors --output-format human-readable-text --compile "$work/MainMenu.nib" "$work/MainMenu.xib"
[ -f "$work/MainMenu.nib" ] || { echo "ibtool produced no nib" >&2; exit 1; }
cp "$work/MainMenu.nib" "$nib/keyedobjects.nib"
cp "$work/MainMenu.nib" "$nib/keyedobjects-101300.nib"
# Xcode decides whether to re-copy the wrapper from the wrapper's own mtime, which overwriting files inside it doesn't change.
touch "$nib"
echo "Compiled $nib"
