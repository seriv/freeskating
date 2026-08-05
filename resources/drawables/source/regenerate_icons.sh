#!/bin/sh
# Regenerates launcher_icon.png and store_cover_500x500.png from the Noun
# Project source artwork (noun-freeskate-5427020.svg, credited to Marcel --
# see README "Icon attribution"). Requires rsvg-convert (brew install
# librsvg). Re-run after editing BG/FG below or the source SVG.
#
# The source SVG's viewBox is 100x125 and includes a "Created by Marcel /
# from the Noun Project" credit baked in as text at y=115-120 -- that's the
# free-preview watermark, not the icon artwork, so it's stripped here rather
# than rasterized into the icon.
set -e

BG="#1E9082"
FG="#000000"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SVG="$SRC_DIR/noun-freeskate-5427020.svg"
TMP_PATHS="$(mktemp)"
TMP_COMPOSED="$(mktemp).svg"

python3 -c "
import re
with open('$SVG') as f:
    svg = f.read()
paths = re.findall(r'<path.*?/>', svg, re.S)
with open('$TMP_PATHS', 'w') as f:
    f.write(''.join(paths))
"

python3 -c "
with open('$TMP_PATHS') as f:
    paths = f.read().replace('fill=\"#000000\"', 'fill=\"$FG\"')

# Bounding box of the artwork paths (excluding the credit text), in the
# original 100x125 viewBox -- computed once from the path coordinates;
# recompute if the source SVG's artwork changes.
bbox_x, bbox_y, bbox_w, bbox_h = 5.65, 25.6, 88.7, 48.79
pad_frac = 0.10
content_max = 100 * (1 - 2 * pad_frac)
scale = min(content_max / bbox_w, content_max / bbox_h)
new_w, new_h = bbox_w * scale, bbox_h * scale
tx, ty = (100 - new_w) / 2, (100 - new_h) / 2

svg = f'''<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\">
<rect x=\"0\" y=\"0\" width=\"100\" height=\"100\" fill=\"$BG\"/>
<g transform=\"translate({tx:.4f},{ty:.4f}) scale({scale:.6f}) translate({-bbox_x:.4f},{-bbox_y:.4f})\">
{paths}
</g>
</svg>'''

with open('$TMP_COMPOSED', 'w') as f:
    f.write(svg)
"

rsvg-convert -w 40 -h 40 "$TMP_COMPOSED" -o "$SRC_DIR/../launcher_icon.png"
rsvg-convert -w 500 -h 500 "$TMP_COMPOSED" -o "$SRC_DIR/../../../store_cover_500x500.png"
rm -f "$TMP_PATHS" "$TMP_COMPOSED"
echo "Regenerated launcher_icon.png and store_cover_500x500.png from $SVG"
