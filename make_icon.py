"""Draws Keeper's app icon (icon.png, 1024x1024): a minimal SD card with a keep mark.

Tweak the colours below and rerun:

    python3 make_icon.py

Then rebuild with ./build_app.sh --install to put the new icon on the app.
"""
import cairosvg

# Catppuccin Mocha: base and mauve. https://catppuccin.com/palette/
BASE = "#1e1e2e"
MAUVE = "#cba6f7"

PLATE = BASE
CARD = MAUVE
CONTACT = BASE
CHECK = BASE

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="92" y="92" width="840" height="840" rx="188" fill="{PLATE}"/>

  <!-- SD card: a rounded rectangle with the bevelled top-left corner, softened at both ends -->
  <path d="M 412 268 L 660 268 Q 696 268 696 304 L 696 720 Q 696 756 660 756 L 364 756
           Q 328 756 328 720 L 328 352 Q 328 340 336 332 L 392 276 Q 400 268 412 268 Z"
        fill="{CARD}"/>

  <!-- contacts -->
  <g fill="{CONTACT}">
    <rect x="446" y="304" width="26" height="86" rx="12"/>
    <rect x="492" y="304" width="26" height="86" rx="12"/>
    <rect x="538" y="304" width="26" height="86" rx="12"/>
    <rect x="584" y="304" width="26" height="86" rx="12"/>
  </g>

  <!-- keep mark -->
  <path d="M 404 586 L 476 658 L 622 512" fill="none" stroke="{CHECK}" stroke-width="62"
        stroke-linecap="round" stroke-linejoin="round"/>
</svg>"""


def main():
    cairosvg.svg2png(bytestring=SVG.encode(), write_to="icon.png",
                     output_width=1024, output_height=1024)
    print("wrote icon.png")


if __name__ == "__main__":
    main()
