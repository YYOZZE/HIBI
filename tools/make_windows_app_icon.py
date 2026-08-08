# -*- coding: utf-8 -*-
"""生成 Windows runner / 安装包用的 app_icon.ico（可重复执行）。

背景：
  Win32/.exe 嵌入的 ICO 不会像 MSIX AppList 那样由系统自动套圆角底板。
  若位图四角不透明（直角或黑角），任务栏上会显得突兀。
  本脚本在图标资源内预烘焙轻度圆角方块（超椭圆 squircle）+ 透明边。

规范要点（Microsoft Learn + 实践）：
  - 尺寸：至少 16/24/32/48/256；本脚本额外包含任务栏常用 20/40/64/128
  - 外形：轻度圆角方块 / PS 式 squircle（非正圆）：
      SQUIRCLE_N 越大越方（n=2 为正圆）；PAD_FRAC 越小 logo 越大越清晰
  - 透明：圆角外 alpha=0，避免黑角在深色任务栏上拼成硬方块
  - 小尺寸：缩放后再按目标尺寸重打 alpha，并对线条略锐化

源图优先顺序：
  1) xhb-image/1_1_dark.png（品牌深色底板，若已生成）
  2) Cursor 资产 logo_candidate_A2_gray_dark.png
  3) xhb-image/1_1.png（回退）

用法：
  python tools/make_windows_app_icon.py

输出：
  windows/runner/resources/app_icon.ico
  tools/_icon_preview/windows_app_icon_{16,32,40,48,256}.png
  xhb-image/1_1_dark_windows_master.png  （1024 透明圆角母版，便于复查）

注意：
  勿再用 `dart run flutter_launcher_icons` 覆盖 Windows 图标（pubspec 已关闭
  windows.generate）；该工具会按直角源图重写 app_icon.ico。
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageFilter

ROOT = r"I:\TSINGDIGITAL\HIBI-2023"
OUT_ICO = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
OUT_MASTER = os.path.join(ROOT, "xhb-image", "1_1_dark_windows_master.png")
PREVIEW_DIR = os.path.join(ROOT, "tools", "_icon_preview")

# 含 Win11 任务栏/标题栏常见档位（见 app-icon-construction）
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
MASTER = 1024

# —— 3.3.11：减小圆角、放大 logo（相对 3.3.7 近圆底板）——
# 旧：PAD_FRAC=0.12 / SQUIRCLE_N=2.4（对角切入大，观感接近正圆，菱形难辨）
# 新：PAD_FRAC=0.04 / SQUIRCLE_N=4.8（轻度圆角方块 / PS squircle）
PAD_FRAC = 0.04
# 超椭圆指数：越大越方。~4.8 为轻度圆角方块，避免接近圆形
SQUIRCLE_N = 4.8
# 品牌图相对底板内缩，给菱形四尖与中心标留安全区（略放大更清晰）
CONTENT_SCALE = 0.94
# 羽化宽度（相对边长）；小尺寸在 remask 时另有下限
FEATHER_FRAC = 0.010


def _candidate_sources() -> list[str]:
    cursor_assets = (
        r"C:\Users\a1306\.cursor\projects\i-TSINGDIGITAL-HIBI-2023\assets"
        r"\logo_candidate_A2_gray_dark.png"
    )
    return [
        os.path.join(ROOT, "xhb-image", "1_1_dark.png"),
        cursor_assets,
        os.path.join(ROOT, "xhb-image", "1_1.png"),
    ]


def resolve_source() -> str:
    for p in _candidate_sources():
        if os.path.isfile(p):
            return p
    raise FileNotFoundError(
        "未找到品牌源图，请提供 xhb-image/1_1_dark.png 或 logo_candidate_A2_gray_dark.png"
    )


def load_plate_rgb(path: str, size: int = MASTER) -> np.ndarray:
    """读取源图，裁到内容区域并缩放到 size；返回 RGB float32 [0,1]。"""
    img = Image.open(path).convert("RGB")
    a = np.asarray(img).astype(np.float32)
    lum = a.sum(axis=2) / 3.0
    # 去掉纯黑角；若整图都是深色底板则退回全幅
    ys, xs = np.where(lum > 10.0)
    if len(xs) < 100:
        ys, xs = np.where(lum > 2.0)
    y0, y1 = int(ys.min()), int(ys.max())
    x0, x1 = int(xs.min()), int(xs.max())
    # 略扩边，避免切掉抗锯齿环
    pad = max(2, int(0.004 * max(img.size)))
    y0, x0 = max(0, y0 - pad), max(0, x0 - pad)
    y1, x1 = min(img.size[1] - 1, y1 + pad), min(img.size[0] - 1, x1 + pad)
    side = max(x1 - x0 + 1, y1 - y0 + 1)
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    half = side / 2.0
    box = (
        int(round(cx - half)),
        int(round(cy - half)),
        int(round(cx + half)),
        int(round(cy + half)),
    )
    crop = img.crop(box).resize((size, size), Image.Resampling.LANCZOS)
    return np.asarray(crop).astype(np.float32) / 255.0


def squircle_alpha(size: int, pad_frac: float, n: float, feather_frac: float) -> np.ndarray:
    """生成 HxW float alpha：超椭圆底板，外缘透明。"""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) / 2.0
    # 有效半径：扣除边距后贴齐中线
    r = (0.5 - pad_frac) * size
    d = (np.abs(xx - c) / r) ** n + (np.abs(yy - c) / r) ** n
    feather = max(1.0, feather_frac * size)
    # d<=1 内部；边缘用 softstep 羽化
    edge = np.clip((1.0 - d) * r / feather + 0.5, 0.0, 1.0)
    return edge.astype(np.float32)


def fit_content(art: np.ndarray, scale: float) -> np.ndarray:
    """将品牌图居中缩放到 scale，四周用边缘底板色填充。"""
    if scale >= 0.999:
        return art
    h, w, _ = art.shape
    side = max(8, int(round(min(h, w) * scale)))
    im = Image.fromarray((np.clip(art, 0, 1) * 255).astype(np.uint8), "RGB")
    small = im.resize((side, side), Image.Resampling.LANCZOS)
    top = art[max(0, int(0.08 * h)), w // 2]
    bot = art[min(h - 1, int(0.92 * h)), w // 2]
    t = (np.arange(h, dtype=np.float32) / max(1, h - 1))[:, None, None]
    grad = top * (1.0 - t) + bot * t  # (H,1,3)
    canvas = np.empty((h, w, 3), dtype=np.float32)
    canvas[:] = grad
    out = Image.fromarray((np.clip(canvas, 0, 1) * 255).astype(np.uint8), "RGB")
    out.paste(small, ((w - side) // 2, (h - side) // 2))
    return np.asarray(out).astype(np.float32) / 255.0


def fill_outside_with_edge_color(art: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """底板外用边缘色填充再乘 alpha，避免半透明环露出错误色。"""
    h, w, _ = art.shape
    # 取上/下边缘中点附近色作竖直微渐变（与 process_logo_2026 一致）
    top = art[max(0, int(0.08 * h)), w // 2]
    bot = art[min(h - 1, int(0.92 * h)), w // 2]
    t = (np.arange(h, dtype=np.float32) / max(1, h - 1))[:, None, None]
    grad = top * (1.0 - t) + bot * t
    a3 = alpha[..., None]
    return art * a3 + grad * (1.0 - a3)


def compose_rgba(art_rgb: np.ndarray, alpha: np.ndarray) -> Image.Image:
    filled = fill_outside_with_edge_color(art_rgb, alpha)
    rgba = np.dstack(
        [
            (np.clip(filled, 0, 1) * 255).astype(np.uint8),
            (np.clip(alpha, 0, 1) * 255).astype(np.uint8),
        ]
    )
    return Image.fromarray(rgba, "RGBA")


def build_master(src: str) -> Image.Image:
    art = fit_content(load_plate_rgb(src, MASTER), CONTENT_SCALE)
    alpha = squircle_alpha(MASTER, PAD_FRAC, SQUIRCLE_N, FEATHER_FRAC)
    return compose_rgba(art, alpha)


def render_size(master: Image.Image, size: int) -> Image.Image:
    """缩放后按目标尺寸重打 squircle，保证任务栏 32/40/48 四角干净透明。"""
    im = master.resize((size, size), Image.Resampling.LANCZOS)
    rgb = np.asarray(im.convert("RGB")).astype(np.float32) / 255.0
    # 小尺寸羽化略宽，避免毛刺；仍强制四角 alpha=0
    feather = FEATHER_FRAC if size >= 48 else max(FEATHER_FRAC, 1.25 / size)
    alpha = squircle_alpha(size, PAD_FRAC, SQUIRCLE_N, feather)
    out = compose_rgba(rgb, alpha)
    if size <= 48:
        # 锐化 RGB，让中心线条在任务栏尺寸更清晰
        pct = 140 if size <= 32 else 120
        sharp = out.convert("RGB").filter(
            ImageFilter.UnsharpMask(radius=0.6, percent=pct, threshold=1)
        )
        out = Image.merge("RGBA", (*sharp.split(), out.getchannel("A")))
    return out


def save_ico(images: list[Image.Image], path: str) -> None:
    # Pillow：主图用最大帧，其余 append；各层以 PNG 压缩写入以保留 alpha
    ordered = sorted(images, key=lambda im: im.size[0])
    largest = ordered[-1]
    rest = ordered[:-1]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    largest.save(
        path,
        format="ICO",
        sizes=[(im.size[0], im.size[1]) for im in ordered],
        append_images=rest,
    )


def verify_ico(path: str) -> None:
    chk = Image.open(path)
    got = sorted(chk.info.get("sizes") or [])
    expect = [(s, s) for s in SIZES]
    assert got == expect, "ico 尺寸不符: got=%r expect=%r" % (got, expect)
    for s in SIZES:
        im = Image.open(path)
        im.size = (s, s)
        im.load()
        rgba = im.convert("RGBA")
        a = np.asarray(rgba)[..., 3]
        # 四角必须完全透明（预烘焙圆角生效）
        corners = [int(a[0, 0]), int(a[0, -1]), int(a[-1, 0]), int(a[-1, -1])]
        assert max(corners) == 0, "尺寸 %d 四角仍不透明: %r" % (s, corners)
        # 中心应不透明
        mid = a[s // 2, s // 2]
        assert mid > 200, "尺寸 %d 中心 alpha 过低: %s" % (s, mid)
        # 任务栏常用尺寸：轻度圆角（非正圆）——对角切入约 4–12%
        if s in (32, 40, 48, 256):
            cut = 0
            for i in range(s):
                if a[i, i] > 128:
                    cut = i
                    break
            min_cut = max(1, int(0.03 * s))
            max_cut = max(min_cut + 1, int(0.14 * s))
            assert cut >= min_cut, "尺寸 %d 圆角不够: cut=%d need>=%d" % (
                s,
                cut,
                min_cut,
            )
            assert cut <= max_cut, "尺寸 %d 圆角过大(近正圆): cut=%d need<=%d" % (
                s,
                cut,
                max_cut,
            )
            t_frac = float((a < 40).sum()) / float(a.size)
            assert 0.03 <= t_frac <= 0.22, "尺寸 %d 透明区占比异常: %.3f" % (
                s,
                t_frac,
            )
            print(
                "OK %d: corner_alpha=%r cut=%dpx (%.1f%%) transparent_frac=%.3f"
                % (s, corners, cut, 100.0 * cut / s, t_frac)
            )
    print("OK sizes:", got)
    print("OK corner transparency verified for all sizes")


def main() -> int:
    src = resolve_source()
    print("source:", src)
    print(
        "pad=%.3f squircle_n=%.2f content_scale=%.2f"
        % (PAD_FRAC, SQUIRCLE_N, CONTENT_SCALE)
    )
    print("compare: old PAD_FRAC=0.12 SQUIRCLE_N=2.4 → new %.3f / %.1f" % (PAD_FRAC, SQUIRCLE_N))
    master = build_master(src)
    os.makedirs(os.path.dirname(OUT_MASTER), exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    master.save(OUT_MASTER, "PNG")
    print("saved:", OUT_MASTER)

    images = [render_size(master, s) for s in SIZES]
    save_ico(images, OUT_ICO)
    print("saved:", OUT_ICO)

    for s in (16, 32, 40, 48, 256):
        p = os.path.join(PREVIEW_DIR, "windows_app_icon_%d.png" % s)
        images[SIZES.index(s)].save(p, "PNG")
        print("preview:", p)

    # 深/浅底预览：确认圆角在深色桌面背景下仍清晰（避免“看起来像直角方块”）
    for bg_name, bg_rgb in (("on_dark", (32, 32, 32)), ("on_light", (240, 240, 240))):
        plate = Image.new("RGBA", (256, 256), bg_rgb + (255,))
        icon = images[SIZES.index(256)].resize((220, 220), Image.Resampling.LANCZOS)
        plate.paste(icon, ((256 - 220) // 2, (256 - 220) // 2), icon)
        p = os.path.join(PREVIEW_DIR, "windows_app_icon_256_%s.png" % bg_name)
        plate.save(p, "PNG")
        print("preview:", p)

    verify_ico(OUT_ICO)
    return 0


if __name__ == "__main__":
    sys.exit(main())
