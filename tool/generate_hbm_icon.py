"""Generate the distinct .hbm file icon from the HIBI app artwork."""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "xhb-image" / "1_1.png"
OUTPUT_DIR = ROOT / "assets" / "icons"


def gear_points(cx: float, cy: float, outer: float, inner: float) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    # Four points per tooth make a compact, readable 10-tooth gear.
    for index in range(40):
        phase = index % 4
        radius = outer if phase in (1, 2) else inner
        angle = -math.pi / 2 + index * math.tau / 40
        points.append((cx + math.cos(angle) * radius, cy + math.sin(angle) * radius))
    return points


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGB")
    side = min(source.size)
    left = (source.width - side) // 2
    top = (source.height - side) // 2
    canvas = source.crop((left, top, left + side, top + side)).resize((1024, 1024), Image.Resampling.LANCZOS).convert("RGBA")

    draw = ImageDraw.Draw(canvas, "RGBA")
    cx, cy = 770, 770
    badge_radius = 218
    draw.ellipse(
        (cx - badge_radius, cy - badge_radius, cx + badge_radius, cy + badge_radius),
        fill=(18, 23, 57, 242),
        outline=(83, 224, 255, 255),
        width=30,
    )
    draw.polygon(gear_points(cx, cy, 150, 116), fill=(241, 248, 255, 255))
    draw.ellipse((cx - 58, cy - 58, cx + 58, cy + 58), fill=(35, 65, 135, 255))
    draw.ellipse((cx - 28, cy - 28, cx + 28, cy + 28), fill=(85, 220, 255, 255))

    png_path = OUTPUT_DIR / "hbm_file_icon.png"
    ico_path = OUTPUT_DIR / "hbm_file_icon.ico"
    canvas.save(png_path, optimize=True)
    canvas.save(ico_path, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print(png_path)
    print(ico_path)


if __name__ == "__main__":
    main()
