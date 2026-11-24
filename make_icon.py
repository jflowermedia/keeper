"""Draws Keeper's app icon (icon.png, 1024x1024): a minimal SD card with a keep mark.

Tweak the colours below and rerun:

    python3 make_icon.py

Then rebuild with ./build_app.sh --install to put the new icon on the app.
"""
import cairosvg

# Catppuccin Mocha. https://catppuccin.com/palette/
BASE = "#1e1e2e"
SURFACE0 = "#313244"
SURFACE1 = "#45475a"
SURFACE2 = "#585b70"
OVERLAY1 = "#7f849c"
PINK = "#f5c2e7"
MAUVE = "#cba6f7"

MARK = BASE     # the contacts and the tick

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{SURFACE0}"/><stop offset="1" stop-color="{BASE}"/>
    </linearGradient>
    <!-- light along the top edge, fading: the plate is nearly invisible on a dark Dock -->
    <linearGradient id="edge" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{OVERLAY1}"/>
      <stop offset=".45" stop-color="{SURFACE2}" stop-opacity=".35"/>
      <stop offset="1" stop-color="{SURFACE1}" stop-opacity=".25"/>
    </linearGradient>
    <linearGradient id="card" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{PINK}"/><stop offset="1" stop-color="{MAUVE}"/>
    </linearGradient>
  </defs>

  <rect x="92" y="92" width="840" height="840" rx="188" fill="url(#plate)"/>
  <rect x="94.5" y="94.5" width="835" height="835" rx="185.5" fill="none" stroke="url(#edge)"
        stroke-width="5"/>

  <g transform="translate(512 512) scale(1.24) translate(-512 -512)">
    <!-- SD card: a rounded rectangle with the bevelled top-left corner, softened at both ends -->
    <path d="M 412 268 L 660 268 Q 696 268 696 304 L 696 720 Q 696 756 660 756 L 364 756
             Q 328 756 328 720 L 328 352 Q 328 340 336 332 L 392 276 Q 400 268 412 268 Z"
          fill="url(#card)"/>

    <!-- contacts -->
    <g fill="{MARK}">
      <rect x="429" y="304" width="38" height="82" rx="19"/>
      <rect x="493" y="304" width="38" height="82" rx="19"/>
      <rect x="557" y="304" width="38" height="82" rx="19"/>
    </g>

    <!-- keep mark -->
    <path d="M 419.1 554.6 L 483.9 619.4 L 604.9 472.6" fill="none" stroke="{MARK}" stroke-width="56"
          stroke-linecap="round" stroke-linejoin="round"/>
  </g>
</svg>"""


def main():
    cairosvg.svg2png(bytestring=SVG.encode(), write_to="icon.png",
                     output_width=1024, output_height=1024)
    print("wrote icon.png")


if __name__ == "__main__":
    main()
