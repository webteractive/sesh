#!/usr/bin/env python3
import re, sys

gear_file, out_file, gear_span = sys.argv[1], sys.argv[2], float(sys.argv[3])
src = open(gear_file).read()

vb = re.search(r'viewBox="([\d.\s-]+)"', src).group(1).split()
vbw = float(vb[2]); vbh = float(vb[3])
paths = re.findall(r'<path\b([^>]*)/?>', src, flags=re.S)

def attr(a, name):
    m = re.search(name + r'="([^"]*)"', a)
    return m.group(1) if m else None

path_els = []
for a in paths:
    d = attr(a, "d")
    if not d:
        continue
    fr = attr(a, "fill-rule")
    fr_attr = f' fill-rule="{fr}"' if fr else ""
    path_els.append(f'<path d="{d}"{fr_attr}/>')

S = 1024.0
C = S / 2
scale = gear_span / max(vbw, vbh)
tx = C - (vbw / 2) * scale
ty = C - (vbh / 2) * scale

gear_group = (
    f'<g transform="translate({tx:.3f} {ty:.3f}) scale({scale:.4f})" '
    f'fill="url(#gear)">' + "".join(path_els) + '</g>'
)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{int(S)}" height="{int(S)}" viewBox="0 0 {int(S)} {int(S)}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#232b39"/>
      <stop offset="1" stop-color="#0e131b"/>
    </linearGradient>
    <linearGradient id="gear" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#d3dbe6"/>
      <stop offset="1" stop-color="#8b97a8"/>
    </linearGradient>
    <radialGradient id="hub" cx="0.5" cy="0.42" r="0.6">
      <stop offset="0" stop-color="#222a37"/>
      <stop offset="1" stop-color="#0d121a"/>
    </radialGradient>
  </defs>

  <rect x="92" y="92" width="840" height="840" rx="188" ry="188" fill="url(#bg)"/>

  {gear_group}

  <!-- dark hub framing the prompt -->
  <circle cx="{int(C)}" cy="{int(C)}" r="150" fill="url(#hub)"/>

  <!-- >_ shell prompt -->
  <g fill="none" stroke="#34d399" stroke-width="30" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="476,462 546,512 476,562"/>
  </g>
  <rect x="486" y="566" width="104" height="28" rx="14" fill="#34d399"/>
</svg>'''

open(out_file, "w").write(svg)
print(f"{gear_file}: viewBox {vbw}x{vbh}, {len(path_els)} path(s), scale {scale:.3f}")
