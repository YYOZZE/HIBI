# -*- coding: utf-8 -*-
"""希比 hibi-2023 软著鉴别材料：lib 下 Dart 源码连续前 30 页 + 后 30 页，每页 55 行。"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

try:
    from fpdf import FPDF
    from fpdf.enums import XPos, YPos
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "fpdf2", "-q"])
    from fpdf import FPDF
    from fpdf.enums import XPos, YPos

LINES_PER_PAGE = 55
# 避免源文件编码导致中文路径乱码：hibi-2023软著登记鉴别材料.pdf
OUTPUT_REL = "hibi-2023\u8f6f\u8457\u767b\u8bb0\u9274\u522b\u6750\u6599.pdf"
FRONT_PAGES = 30
BACK_PAGES = 30


def find_cn_font() -> Path:
    for p in [
        Path(r"C:\Windows\Fonts\simfang.ttf"),
        Path(r"C:\Windows\Fonts\simsun.ttc"),
        Path(r"C:\Windows\Fonts\simhei.ttf"),
        Path(r"C:\Windows\Fonts\msyh.ttc"),
    ]:
        if p.exists():
            return p
    raise SystemExit("未找到 Windows 中文字体（仿宋/黑体等），无法生成含中文注释的 PDF。")


def collect_lines(project_root: Path) -> list[str]:
    lib = project_root / "lib"
    files = sorted(lib.rglob("*.dart"))
    out: list[str] = []
    for fp in files:
        rel = fp.relative_to(project_root).as_posix()
        try:
            text = fp.read_text(encoding="utf-8")
        except OSError:
            text = fp.read_text(encoding="utf-8", errors="replace")
        out.append(f"// ========== {rel} ==========")
        out.extend(text.splitlines())
        out.append("")
    return out


def main() -> None:
    project_root = Path(__file__).resolve().parents[1]
    out_pdf = project_root / OUTPUT_REL
    font = find_cn_font()

    lines = collect_lines(project_root)
    total = len(lines)
    n_front = FRONT_PAGES * LINES_PER_PAGE
    n_back = BACK_PAGES * LINES_PER_PAGE

    front = lines[:n_front]
    back = lines[max(0, total - n_back) :]

    pdf = FPDF(unit="mm", format="A4")
    pdf.set_auto_page_break(False)
    pdf.add_font("cn", "", str(font))

    margin_l, margin_r, margin_t = 12, 12, 18
    page_w = 210
    usable_w = page_w - margin_l - margin_r

    def draw_section_banner(title: str) -> None:
        pdf.set_font("cn", "", 11)
        pdf.set_xy(margin_l, margin_t)
        pdf.multi_cell(usable_w, 6, title, align="L")

    line_h = 4.35
    max_y = 297 - 18

    def emit_block(section_title: str, block: list[str]) -> None:
        global_idx = 0
        page_idx = 0
        while global_idx < len(block):
            pdf.add_page()
            pdf.set_margins(margin_l, margin_t, margin_r)
            page_idx += 1
            y = margin_t
            if page_idx == 1:
                draw_section_banner(section_title)
                y = pdf.get_y() + 2
            pdf.set_font("cn", "", 6.8)
            pdf.set_xy(margin_l, y)
            for _ in range(LINES_PER_PAGE):
                if global_idx >= len(block):
                    break
                raw = block[global_idx].replace("\t", "    ")
                global_idx += 1
                if len(raw) > 120:
                    raw = raw[:117] + "..."
                pdf.cell(usable_w, line_h, raw, new_x=XPos.LMARGIN, new_y=YPos.NEXT)
            pdf.set_y(max_y - 2)
            pdf.set_font("cn", "", 8)
            pdf.cell(0, 5, f"\u7b2c {pdf.page_no()} \u9875", align="C")

    meta = (
        f"\u8f6f\u4ef6\u540d\u79f0\uff1a\u5e0c\u6bd4 HIBI\uff08hibi-2023 / jideshi_hibi\uff09\n"
        f"\u6e90\u7a0b\u5e8f\u8303\u56f4\uff1a\u9879\u76ee\u76ee\u5f55 lib \u4e0b\u5168\u90e8 .dart "
        f"\u6587\u4ef6\uff08\u6309\u8def\u5f84\u6392\u5e8f\u8fde\u7eed\u62fc\u63a5\uff09\n"
        f"\u62fc\u63a5\u603b\u884c\u6570\uff1a{total} \u884c\uff08\u542b\u6587\u4ef6\u5206\u9694\u6807\u8bb0\u884c\uff09\n"
        f"\u8282\u9009\u89c4\u5219\uff1a\u524d {n_front} \u884c\uff08{FRONT_PAGES} \u9875 \u00d7 {LINES_PER_PAGE} \u884c/\u9875\uff09"
        f" + \u540e {n_back} \u884c\uff08{BACK_PAGES} \u9875 \u00d7 {LINES_PER_PAGE} \u884c/\u9875\uff09\n"
        f"\u8bf4\u660e\uff1a\u82e5\u6e90\u4ee3\u7801\u603b\u884c\u6570\u4e0d\u8db3 {n_front + n_back} "
        f"\u884c\uff0c\u524d\u540e\u4e24\u90e8\u5206\u53ef\u80fd\u91cd\u53e0\u3002"
    )
    pdf.add_page()
    pdf.set_font("cn", "", 10)
    pdf.set_margin(15)
    pdf.multi_cell(
        0,
        5,
        "\u8f6f\u4ef6\u8457\u4f5c\u6743\u767b\u8bb0 \u00b7 \u9274\u522b\u6750\u6599\uff08\u6e90\u4ee3\u7801\u8282\u9009\uff09",
        align="C",
    )
    pdf.ln(4)
    pdf.set_font("cn", "", 9)
    pdf.multi_cell(0, 5, meta, align="L")

    emit_block(
        f"\u3010\u6e90\u4ee3\u7801 \u00b7 \u524d\u8fde\u7eed {FRONT_PAGES} "
        f"\u9875\uff0c\u6bcf\u9875 {LINES_PER_PAGE} \u884c\uff0c\u5171 {len(front)} \u884c\u3011",
        front,
    )
    emit_block(
        f"\u3010\u6e90\u4ee3\u7801 \u00b7 \u540e\u8fde\u7eed {BACK_PAGES} "
        f"\u9875\uff0c\u6bcf\u9875 {LINES_PER_PAGE} \u884c\uff0c\u5171 {len(back)} \u884c\u3011",
        back,
    )

    pdf.output(str(out_pdf))
    print("Generated:", out_pdf)
    print("lib lines:", total, "front:", len(front), "back:", len(back))


if __name__ == "__main__":
    main()
