#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == --help ]]; then
    printf '%s\n' 'Usage: bash Build/generate-fork-icons.sh' 'Regenerate the committed Flycut GPT app and menu icons from Resources SVG sources.' 'Requires librsvg, ImageMagick, and macOS iconutil.'
    exit 0
fi
if [[ $# -ne 0 ]]; then
    printf '%s\n' 'Usage: bash Build/generate-fork-icons.sh' >&2
    exit 2
fi
command -v magick >/dev/null
command -v iconutil >/dev/null
command -v rsvg-convert >/dev/null
root=$(dirname "$(dirname "$(realpath "$0")")")
mkdir -p "$root/tmp"
scratch=$(mktemp -d "$root/tmp/flycut-gpt-icons.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/flycut-gpt.iconset"

rsvg-convert --width 1024 --height 1024 --output "$scratch/master.png" "$root/Resources/flycut-gpt-icon.svg"
for size in 16 32 128 256 512; do
    magick "$scratch/master.png" -resize "${size}x${size}" -define png:exclude-chunks=date,time "$scratch/flycut-gpt.iconset/icon_${size}x${size}.png"
    retina=$((size * 2))
    magick "$scratch/master.png" -resize "${retina}x${retina}" -define png:exclude-chunks=date,time "$scratch/flycut-gpt.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$scratch/flycut-gpt.iconset" -o "$root/flycut-gpt.icns"
for state in scissors scissors-paused; do
    if [[ "$state" == scissors ]]; then name=FlycutGPTScissors; else name=FlycutGPTScissorsPaused; fi
    rsvg-convert --width 16 --height 16 --output "$root/Resources/${name}.png" "$root/Resources/flycut-gpt-${state}.svg"
    rsvg-convert --width 32 --height 32 --output "$root/Resources/${name}@2x.png" "$root/Resources/flycut-gpt-${state}.svg"
    for icon in "$root/Resources/${name}.png" "$root/Resources/${name}@2x.png"; do
        if [[ $(magick "$icon" -format '%[fx:maxima.a>0]' info:) != 1 ]]; then
            printf 'Empty icon render: %s\n' "$icon" >&2
            exit 1
        fi
    done
done
printf '%s\n' 'Generated flycut-gpt.icns and both menu-icon resolutions.'
