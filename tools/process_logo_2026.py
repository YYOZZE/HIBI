# -*- coding: utf-8 -*-
"""处理双版灰色 Logo（跟随系统亮/暗）：
- A1 浅灰 -> xhb-image/1_1.png（全幅）+ 1_1_fg.png（四角透明前景）+ 1_1_mono.png（Android 单色图标）
- A2 深灰 -> xhb-image/1_1_dark.png（全幅，iOS 深色变体 / Windows 图标用）
生成图为满幅 squircle、四角黑色：裁剪后四角用边缘渐变填充（全幅版）或置透明（前景版）。
"""
import os

import numpy as np
from PIL import Image

OUT = r"I:\TSINGDIGITAL\HIBI-2023\xhb-image"
SIZE = 1024

ANDROID_RES = r"I:\TSINGDIGITAL\HIBI-2023\android\app\src\main\res"
DENSITIES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

SOURCES = [
    # (源图, 全幅输出, 前景输出或 None)
    (r"C:\Users\a1306\.cursor\projects\i-TSINGDIGITAL-HIBI-2023\assets\logo_candidate_A1_gray_light.png",
     OUT + r"\1_1.png", OUT + r"\1_1_fg.png"),
    (r"C:\Users\a1306\.cursor\projects\i-TSINGDIGITAL-HIBI-2023\assets\logo_candidate_A2_gray_dark.png",
     OUT + r"\1_1_dark.png", None),
]


def load_art(path: str) -> np.ndarray:
    """读取源图 -> 裁剪亮色 squircle 区域 -> 1024 RGB float"""
    img = Image.open(path).convert("RGB")
    a = np.asarray(img).astype(np.int16)
    lum = a.sum(axis=2) / 3.0
    ys, xs = np.where(lum > 40)  # 深灰版背景本身 ~43，用较低阈值取整体
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    side = min(x1 - x0 + 1, y1 - y0 + 1)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    crop = img.crop((cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side))
    crop = crop.resize((SIZE, SIZE), Image.LANCZOS)
    return np.asarray(crop).astype(np.float32) / 255.0


def squircle_alpha() -> np.ndarray:
    """超椭圆蒙版（HxWx1，边缘羽化）"""
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    c = (SIZE - 1) / 2.0
    r = SIZE / 2.0
    d = (np.abs(xx - c) / r) ** 4.6 + (np.abs(yy - c) / r) ** 4.6
    edge = np.clip((1.04 - d) * SIZE / 6.0, 0.0, 1.0)
    return np.where(d <= 1.04, edge, 0.0)[..., None]


def process(src, full_out, fg_out):
    art = load_art(src)
    alpha = squircle_alpha()

    # 全幅：四角用上下边缘色竖直渐变填充
    top = art[8, SIZE // 2]
    bot = art[SIZE - 9, SIZE // 2]
    t = (np.arange(SIZE, dtype=np.float32) / (SIZE - 1.0))[:, None, None]
    grad = top * (1 - t) + bot * t
    full = art * alpha + grad * (1 - alpha)
    Image.fromarray((np.clip(full, 0, 1) * 255).astype(np.uint8), "RGB").save(full_out, "PNG")

    if fg_out:
        rgba = np.dstack([(art * 255).astype(np.uint8), (alpha[..., 0] * 255).astype(np.uint8)])
        Image.fromarray(rgba, "RGBA").save(fg_out, "PNG")
    print("saved:", full_out, fg_out or "")


def make_mono(fg_path: str, mono_out: str):
    """Android 单色图标：取前景 alpha，线条统一为白色（系统主题图标自动着色）"""
    fg = np.asarray(Image.open(fg_path).convert("RGBA"))
    a = fg[..., 3]
    # 线条与底区分：亮度低于底色的笔画作为图形（底色银白、笔画石墨）
    lum = fg[..., :3].astype(np.float32).sum(axis=2) / 3.0
    ink = np.clip((235.0 - lum) / 120.0, 0.0, 1.0)
    mono_alpha = (ink * (a > 0) * 255).astype(np.uint8)
    white = np.full_like(fg[..., :3], 255)
    Image.fromarray(np.dstack([white, mono_alpha]), "RGBA").save(mono_out, "PNG")
    print("saved:", mono_out)


def make_dark_fg():
    """暗色前景：1_1_dark.png（满幅）叠加 squircle 蒙版 -> 1_1_dark_fg.png（四角透明）"""
    img = Image.open(OUT + r"\1_1_dark.png").convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    art = np.asarray(img).astype(np.float32) / 255.0
    alpha = squircle_alpha()
    rgba = np.dstack([(art * 255).astype(np.uint8), (alpha[..., 0] * 255).astype(np.uint8)])
    Image.fromarray(rgba, "RGBA").save(OUT + r"\1_1_dark_fg.png", "PNG")
    print("saved:", OUT + r"\1_1_dark_fg.png")


def make_dark_density_fgs():
    """暗色前景按密度缩放 -> drawable-night-*/ic_launcher_foreground.png（系统暗色模式图标）"""
    fg = Image.open(OUT + r"\1_1_dark_fg.png").convert("RGBA")
    for name, px in DENSITIES.items():
        d = os.path.join(ANDROID_RES, f"drawable-night-{name}")
        os.makedirs(d, exist_ok=True)
        fg.resize((px, px), Image.LANCZOS).save(os.path.join(d, "ic_launcher_foreground.png"), "PNG")
        print("saved:", d, f"{px}px")


for s, f, g in SOURCES:
    process(s, f, g)

make_mono(OUT + r"\1_1_fg.png", OUT + r"\1_1_mono.png")

make_dark_fg()
make_dark_density_fgs()
