#!/bin/sh
# Renders the app icon set from the SVG sources in this folder.
#
# app-icon.svg is the icon as designed. app-icon-small.svg is the same key with
# heavier strokes and the prompt reduced to its chevron, used for the 16 px and
# 32 px renditions, where the regular strokes thin out to under two pixels.
#
# The menu-bar glyph is not rendered here: it ships as a vector template image,
# App/Resources/Assets.xcassets/MenuBarIcon.imageset/menubar.svg.
#
# Needs rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")"

command -v rsvg-convert >/dev/null 2>&1 \
  || { echo "error: rsvg-convert not found — brew install librsvg" >&2; exit 1; }

OUT=../../App/Resources/Assets.xcassets/AppIcon.appiconset

# render <pixels> <filename>
render() {
  if [ "$1" -le 32 ]; then src=app-icon-small.svg; else src=app-icon.svg; fi
  rsvg-convert -w "$1" -h "$1" "$src" -o "$OUT/$2"
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

echo "Rendered the app icon set into $OUT"
