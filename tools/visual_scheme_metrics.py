#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""方案评审辅助：对渲染结果做像素级客观度量（内部对比证据，任务书 6.2）。

度量项：
1. 主线/描边/GPS/重规划段在普通与阳光底图上的 WCAG 相对亮度对比度；
2. 底部去/返共路段：两侧方向标注像素是否同时可见（6.2 重叠要求）；
3. 图层可区分性：GPS 橙 vs 主线蓝的色差（CIE 近似，越大越不混淆）。
"""
import math
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "docs", "visual")


def lum(rgb):
    def ch(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = rgb[:3]
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def contrast(c1, c2):
    l1, l2 = lum(c1), lum(c2)
    if l1 < l2:
        l1, l2 = l2, l1
    return (l1 + 0.05) / (l2 + 0.05)


def color_dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def count_near(img, box, target, tol=60):
    n = 0
    for x in range(box[0], box[1]):
        for y in range(box[2], box[3]):
            p = img.getpixel((x, y))
            if color_dist(p, target) < tol:
                n += 1
    return n


def main():
    print("=" * 62)
    print("方案像素级评审（普通底图）")
    print("=" * 62)
    # 设计参数层面的对比度（与渲染无关，可复算）
    bg_normal = (245, 243, 234)
    bg_sun = (252, 251, 244)
    road = (253, 252, 249)
    rows = [
        ("A 主线渐变首色 #2979FF", (41, 121, 255)),
        ("A 主线渐变尾色 #00E5FF", (0, 229, 255)),
        ("A 已跑蓝灰 (a=165/255 合成)", None),
        ("A GPS 橙 #FF3D00", (255, 61, 0)),
        ("A 重规划琥珀 #FFB300", (255, 179, 0)),
        ("B 主线 #1565C0", (21, 101, 192)),
        ("B 主线亮部 #1E88E5", (30, 136, 229)),
        ("B GPS 橙 #FF6D00", (255, 109, 0)),
        ("B 重规划 #FFC400", (255, 196, 0)),
    ]
    # 已跑层合成色（alpha over bg）
    doneA = tuple(round((120, 144, 156)[i] * 165 / 255 + bg_normal[i] * (1 - 165 / 255)) for i in range(3))
    doneB = tuple(round((144, 164, 174)[i] * 110 / 255 + bg_normal[i] * (1 - 110 / 255)) for i in range(3))
    print(f"{'样式':36s} {'vs米底':>7s} {'vs阳光':>7s} {'vs道路':>7s}")
    for name, col in rows:
        if col is None:
            col = doneA if name.startswith("A") else doneB
        print(f"{name:36s} {contrast(col, bg_normal):7.2f} "
              f"{contrast(col, bg_sun):7.2f} {contrast(col, road):7.2f}")
    print()
    print("图层可区分性（色差，>120 视为一眼可分）：")
    print(f"  A: GPS橙 vs 主线蓝  = {color_dist((255,61,0),(41,121,255)):.0f}")
    print(f"  A: 重规划琥珀 vs GPS橙 = {color_dist((255,179,0),(255,61,0)):.0f}")
    print(f"  A: 重规划琥珀 vs 主线蓝 = {color_dist((255,179,0),(41,121,255)):.0f}")
    print(f"  B: GPS橙 vs 主线蓝  = {color_dist((255,109,0),(21,101,192)):.0f}")
    print(f"  B: 重规划黄 vs GPS橙 = {color_dist((255,196,0),(255,109,0)):.0f}")
    print(f"  B: 重规划黄 vs 主线蓝 = {color_dist((255,196,0),(21,101,192)):.0f}")

    print()
    print("=" * 62)
    print("渲染像素验证：底部去/返共路段双侧标注同时可见（6.2）")
    print("=" * 62)
    for tag, f, out_col, back_col in (
            ("A", "scheme_a.png", (13, 71, 161), (0, 105, 92)),
            ("B", "scheme_b.png", (13, 71, 161), (0, 121, 107))):
        img = Image.open(os.path.join(OUT, f)).convert("RGB")
        # 去程箭头带（底路 y=1230 上侧偏移 -9 → y≈1212-1226，取 x 300-400）
        up = count_near(img, (300, 400, 1208, 1226), out_col, tol=90)
        dn = count_near(img, (600, 700, 1234, 1252), back_col, tol=90)
        print(f"  方案{tag}: 去程侧箭头像素={up:4d}  返程侧箭头像素={dn:4d}  "
              f"→ {'双侧可见 ✓' if up > 20 and dn > 20 else '不可见 ✗'}")

    print()
    print("阳光直射模拟（sunlight.png 已渲染，指标同上表的 vs阳光 列）")


if __name__ == "__main__":
    main()
