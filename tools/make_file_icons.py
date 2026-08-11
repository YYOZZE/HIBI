# -*- coding: utf-8 -*-
"""生成 .hbm 文件关联图标 assets/icons/hbm_file_icon.ico（可重复执行）。

底图：xhb-image/1_1_dark.png（石墨底 #232529 + 银色线条，文件管理器亮/暗主题下均清晰）。
右下角徽标：延续旧图标的「齿轮圆章」识别特征（用户以此辨认导出文件），
改为与 Logo 协调的石墨圆底 + 银色细环 + 银色八齿齿轮。
仅 48px 及以上尺寸绘制徽标；16/24/32 小尺寸省略，避免糊成一团。

用法：python tools/make_file_icons.py
输出：
  assets/icons/hbm_file_icon.ico      多尺寸 16/24/32/48/64/128/256
  assets/icons/hbm_file_icon_128_preview.png  人工预览
同时自检：重新打开 ico 校验尺寸齐全且可解码。
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw

ROOT = r"I:\TSINGDIGITAL\HIBI-2023"
SRC = ROOT + r"\xhb-image\1_1_dark.png"
OUT_ICO = ROOT + r"\assets\icons\hbm_file_icon.ico"
OUT_PREVIEW = ROOT + r"\assets\icons\hbm_file_icon_128_preview.png"

SIZES = [16, 24, 32, 48, 64, 128, 256]
GEAR_MIN_SIZE = 48          # 小于该尺寸不画齿轮徽标
SS = 4                      # 超采样倍率（抗锯齿）

# 徽标几何（相对图标边长，与旧图标实测一致：圆心约 (0.75, 0.75)，圆章直径约 1/3）
BADGE_CX = BADGE_CY = 0.75
BADGE_R = 1.0 / 6.0
# 配色：石墨底 + 银环 + 银齿轮
BADGE_FILL = (36, 38, 43, 255)
BADGE_RING = (205, 208, 214, 255)
GEAR_COLOR = (216, 219, 225, 255)
GEAR_HOLE = (36, 38, 43, 255)


def draw_badge(size: int) -> Image.Image:
    """生成带右下角齿轮徽标的 RGBA 图层（与底图同尺寸，超采样绘制）。"""
    s = size * SS
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx = cy = BADGE_CX * s
    R = BADGE_R * s
    ring_w = max(SS * 1.5, R * 0.09)

    # 圆底 + 银环
    d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=BADGE_FILL)
    d.ellipse([cx - R, cy - R, cx + R, cy + R],
              outline=BADGE_RING, width=int(round(ring_w)))

    # 八齿齿轮：梯形齿 + 中心孔
    r_tip = 0.62 * R
    r_root = 0.42 * R
    hole_r = 0.19 * R
    n = 8
    half_tooth = math.pi / n * 0.40      # 齿顶/齿根各张 0.4 个槽距
    pts = []
    for i in range(n):
        a0 = i * 2 * math.pi / n
        for ang, rad in ((a0 - half_tooth, r_root), (a0 - half_tooth, r_tip),
                         (a0 + half_tooth, r_tip), (a0 + half_tooth, r_root)):
            pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    d.polygon(pts, fill=GEAR_COLOR)
    d.ellipse([cx - hole_r, cy - hole_r, cx + hole_r, cy + hole_r], fill=GEAR_HOLE)
    return layer


def make_icon_image(base: Image.Image, size: int) -> Image.Image:
    im = base.resize((size, size), Image.LANCZOS)
    if size >= GEAR_MIN_SIZE:
        badge = draw_badge(size).resize((size, size), Image.LANCZOS)
        im = Image.alpha_composite(im, badge)
    return im


def main():
    base = Image.open(SRC).convert("RGBA")
    images = [make_icon_image(base, s) for s in SIZES]

    os.makedirs(os.path.dirname(OUT_ICO), exist_ok=True)
    images[-1].save(OUT_ICO, format="ICO", sizes=[(s, s) for s in SIZES],
                    append_images=images[:-1])
    images[SIZES.index(128)].save(OUT_PREVIEW, "PNG")

    # 自检：重开 ico，校验尺寸齐全、逐帧可解码
    chk = Image.open(OUT_ICO)
    got = sorted(chk.info.get("sizes") or [])
    assert got == [(s, s) for s in SIZES], "ico 尺寸不符: %r" % (got,)
    for s in SIZES:
        im = Image.open(OUT_ICO)
        im.size = (s, s)
        im.load()
        assert im.size == (s, s), "帧 %d 解码失败" % s
    print("OK sizes:", got)
    print("saved:", OUT_ICO)
    print("saved:", OUT_PREVIEW)


if __name__ == "__main__":
    main()
