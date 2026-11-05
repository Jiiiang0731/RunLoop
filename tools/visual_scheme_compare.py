#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 M-F：路线视觉双方案离屏对比渲染（任务书 6.2「至少两套视觉方案
进行内部对比，选择更清晰、更协调的一套」）。

本机无真机/模拟器，高德底图无法离线截屏——本脚本用 PIL 在**模拟底图**
（道路 + 路名 + 楼块）上按 1:1 的样式参数（线宽 dp 比例、颜色、描边、
箭头形态、去/返区分、重叠双侧标注）渲染两套方案，供内部评审对比。
真机高德底图截图列入待验证清单。

场景覆盖规范 6.1–6.3 的全部考察点：
- 细主线 + 分层描边 + 渐变（6.1）；
- 自然转角（圆角连接，绝不平滑出道路）——几何即道路中心线（6.1）；
- 去程/返程共用一条道路、方向相反：双侧方向标注同时可见（6.2）；
- 直行段稀疏箭头、转弯处转弯标注（6.2）；
- 五图层：canonical 参考线 / 剩余主线 / 已跑融合层 / GPS 真实轨迹 /
  重规划连接段（6.3）；
- 阳光直射模拟：同一方案再渲染一版高亮低对比底图（6.4）。

输出：docs/visual/scheme_a.png、scheme_b.png、compare.png、sunlight.png
"""
import math
import os
from typing import List, Tuple

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "docs", "visual")
os.makedirs(OUT, exist_ok=True)

W, H = 1000, 1350
PX_PER_M = 0.35  # 仅用于比例注释，无实义

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
]


def font(size: int) -> ImageFont.FreeTypeFont:
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


Pt = Tuple[float, float]

# ---------------- 场景几何（像素 = 道路中心线，绝不做离开道路的平滑） ----------------

# 环线：起点(500,1230) → 西行 → 北行 → 东行 → 南行 → 回到起点西侧
# 底部道路 y=1230 被跑两次：去程向西（500→170）、返程向东（870→500）。
LOOP_WEST: List[Pt] = [(500, 1230), (170, 1230)]          # 去程：底路西行
LOOP_NORTH: List[Pt] = [(170, 1230), (170, 300)]           # 西侧路北行
LOOP_TOP: List[Pt] = [(170, 300), (870, 300)]              # 顶路东行
LOOP_SOUTH: List[Pt] = [(870, 300), (870, 1230)]           # 东侧路南行
LOOP_BACK: List[Pt] = [(870, 1230), (500, 1230)]           # 返程：底路东行

# 完整环线（顺时针）
FULL_ROUTE: List[Pt] = (LOOP_WEST + LOOP_NORTH[1:] + LOOP_TOP[1:]
                        + LOOP_SOUTH[1:] + LOOP_BACK[1:])

# 跑步进度：已跑 = 起点 → 西 → 北 → 顶路一半；剩余 = 顶路后一半 → 东 → 南 → 返程
SPLIT_FRAC = 0.42

# GPS 真实轨迹：大体沿路线，但在顶路转弯处真实切角/漂移（诚实展示偏离）
GPS_WOBBLE = [(505, 1236), (300, 1224), (166, 1226), (160, 900), (176, 600),
              (168, 310), (240, 292), (420, 306), (515, 296)]

# 重规划连接段（琥珀）：从 GPS 当前位置 (515,296) 接入顶路剩余部分 (620,300)
REROUTE_SEG: List[Pt] = [(515, 296), (560, 318), (620, 300)]

# 背景路网（与路线共线的道路 + 若干交叉路）
BG_ROADS = [
    ([(90, 1230), (950, 1230)], 34, "滨江路"),
    ([(170, 240), (170, 1310)], 30, "中山路"),
    ([(110, 300), (930, 300)], 30, "解放大道"),
    ([(870, 250), (870, 1290)], 26, "建设路"),
    ([(90, 760), (950, 760)], 22, "友谊路"),
    ([(520, 250), (520, 1290)], 22, "体育馆路"),
]
BG_BLOCKS = [  # 楼块（浅灰矩形，验证「不遮盖道路与建筑名称」）
    (230, 380, 460, 700), (580, 380, 810, 700),
    (230, 830, 460, 1160), (580, 830, 810, 1160),
]


# ---------------- 绘制工具 ----------------

def poly_len(pts: List[Pt]) -> float:
    return sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def point_at(pts: List[Pt], frac: float) -> Tuple[Pt, float]:
    """折线按里程比例取点与切线方位（度，屏幕坐标：0=上，顺时针）。"""
    total = poly_len(pts)
    target = total * max(0.0, min(1.0, frac))
    acc = 0.0
    for i in range(len(pts) - 1):
        seg = math.dist(pts[i], pts[i + 1])
        if acc + seg >= target and seg > 0:
            t = (target - acc) / seg
            x = pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t
            y = pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t
            ang = math.degrees(math.atan2(pts[i + 1][1] - pts[i][1],
                                          pts[i + 1][0] - pts[i][0]))
            return (x, y), ang + 90  # 屏幕角→「箭头指向上方为 0」约定
        acc += seg
    return pts[-1], 0.0


def draw_poly(draw: ImageDraw.ImageDraw, pts: List[Pt], color, width: int,
              joint="curve"):
    draw.line(pts, fill=color, width=width, joint=joint)


def draw_gradient_poly(img: Image.Image, pts: List[Pt], c1: Tuple[int, int, int],
                       c2: Tuple[int, int, int], width: int):
    """沿线渐变主线：逐段插值色（高德 Polyline gradient 的离屏等价）。"""
    d = ImageDraw.Draw(img, "RGBA")
    total = poly_len(pts)
    acc = 0.0
    for i in range(len(pts) - 1):
        seg = math.dist(pts[i], pts[i + 1])
        t = (acc + seg / 2) / total if total else 0
        col = tuple(round(c1[k] + (c2[k] - c1[k]) * t) for k in range(3))
        d.line([pts[i], pts[i + 1]], fill=col + (255,), width=width)
        acc += seg


def draw_arrow_filled(d: ImageDraw.ImageDraw, c: Pt, ang: float, color,
                      size=13, outline=(255, 255, 255, 255), ow=3):
    """实心箭头（带白描边）——方案 A 风格。ang: 0=向上，顺时针。"""
    a = math.radians(ang)
    def rot(p):
        x, y = p
        return (c[0] + x * math.cos(a) - y * math.sin(a),
                c[1] + x * math.sin(a) + y * math.cos(a))
    poly = [rot((0, -size)), rot((size * 0.62, size * 0.7)),
            rot((0, size * 0.32)), rot((-size * 0.62, size * 0.7))]
    if outline:
        d.polygon(poly, fill=None, outline=outline)
        d.line(poly + [poly[0]], fill=outline, width=ow)
    d.polygon(poly, fill=color)


def draw_chevron(d: ImageDraw.ImageDraw, c: Pt, ang: float, color,
                 size=11, width=4, filled=True):
    """开放人字形箭头（圆头描边，轻量现代）——方案 B 风格。"""
    a = math.radians(ang)
    def rot(p):
        x, y = p
        return (c[0] + x * math.cos(a) - y * math.sin(a),
                c[1] + x * math.sin(a) + y * math.cos(a))
    pts = [rot((-size * 0.7, size * 0.55)), rot((0, -size * 0.55)),
           rot((size * 0.7, size * 0.55))]
    if filled:
        d.polygon(pts + [pts[0]], fill=None, outline=color)
        d.line(pts, fill=color, width=width)
    else:  # 空心（返程形态编码：形状 + 颜色双区分）
        d.line(pts, fill=color, width=max(2, width - 1))


def offset_leg(pts: List[Pt], dx: float, dy: float) -> List[Pt]:
    """整条腿的屏幕像素级平移（去/返共路时双侧呈现；不修改真实坐标语义，
    与 App 的 turnAnnotationPxOffset 同思路）。"""
    return [(x + dx, y + dy) for x, y in pts]


# ---------------- 底图 ----------------

def draw_basemap(img: Image.Image, sunlight: bool):
    d = ImageDraw.Draw(img, "RGBA")
    bg = (252, 251, 244) if sunlight else (245, 243, 234)
    d.rectangle([0, 0, W, H], fill=bg)
    # 楼块
    block = (238, 235, 224) if sunlight else (232, 229, 216)
    for (x0, y0, x1, y1) in BG_BLOCKS:
        d.rectangle([x0, y0, x1, y1], fill=block)
    # 公园绿地
    green = (226, 240, 214) if sunlight else (214, 235, 199)
    d.rectangle([580, 830, 810, 1160], fill=green)
    # 道路
    road = (255, 255, 255) if sunlight else (253, 252, 249)
    road_edge = (222, 220, 208) if sunlight else (210, 208, 196)
    f_lab = font(24 if not sunlight else 25)
    for pts, width, name in BG_ROADS:
        d.line(pts, fill=road_edge, width=width + 4)
        d.line(pts, fill=road, width=width)
        mid, ang = point_at(pts, 0.5)
        col = (150, 148, 138) if sunlight else (122, 120, 110)
        d.text((mid[0] + 14, mid[1] - 34), name, font=f_lab, fill=col)
    # 建筑名称（验证路线不遮盖文字）
    f_b = font(20)
    for (x, y, t) in [(300, 520, "体育中心"), (650, 520, "中央广场"),
                      (300, 970, "人民医院"), (660, 970, "滨江公园")]:
        d.text((x, y), t, font=f_b, fill=(140, 138, 128))


# ---------------- 方案 A：导航对比风（白描边 + 渐变主线 + 实心箭头） ----------------

SCHEME_A = dict(
    name="方案 A · 导航对比风",
    desc="白色实体描边 + 蓝青渐变主线 + 实心箭头（去=深蓝实/返=青绿实）",
    casing=(255, 255, 255, 255), casing_w=11,
    core1=(41, 121, 255), core2=(0, 229, 255), core_w=6,
    done=(120, 144, 156, 165), done_w=5,
    gps_c=(255, 255, 255, 255), gps_c_w=11, gps=(255, 61, 0, 255), gps_w=7,
    reroute=(255, 179, 0, 255), reroute_c=(255, 255, 255, 255), reroute_w=7,
    canonical=(120, 144, 156, 90), canonical_w=3,
    arrow_out=(13, 71, 161, 255), arrow_back=(0, 105, 92, 255),
    arrow_kind="filled", turn_style="circle",
)

# ---------------- 方案 B：轻量径迹风（彩色光晕 + 细主线 + 开放箭头形编码） ----------------

SCHEME_B = dict(
    name="方案 B · 轻量径迹风",
    desc="同色半透明光晕 + 更细实色主线 + 开放箭头（去=实心形/返=空心形，形状+颜色双编码）",
    casing=(21, 101, 192, 55), casing_w=13,
    core1=(21, 101, 192), core2=(30, 136, 229), core_w=5,
    done=(144, 164, 174, 110), done_w=4,
    gps_c=(255, 255, 255, 210), gps_c_w=9, gps=(255, 109, 0, 255), gps_w=6,
    reroute=(255, 196, 0, 255), reroute_c=(255, 255, 255, 200), reroute_w=6,
    canonical=(144, 164, 174, 70), canonical_w=2,
    arrow_out=(13, 71, 161, 255), arrow_back=(0, 121, 107, 255),
    arrow_kind="chevron", turn_style="minimal",
)


def split_route(pts: List[Pt], frac: float):
    total = poly_len(pts)
    cut = total * frac
    done, remain = [pts[0]], []
    acc = 0.0
    for i in range(len(pts) - 1):
        seg = math.dist(pts[i], pts[i + 1])
        if acc + seg < cut:
            done.append(pts[i + 1])
            acc += seg
        else:
            t = (cut - acc) / seg if seg else 0
            mid = (pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t,
                   pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t)
            done.append(mid)
            remain = [mid] + pts[i + 1:]
            break
    return done, remain


def draw_scheme(img: Image.Image, s: dict, sunlight: bool):
    draw_basemap(img, sunlight)
    d = ImageDraw.Draw(img, "RGBA")
    done, remain = split_route(FULL_ROUTE, SPLIT_FRAC)

    # 1) canonical 参考线（重规划后保留原路线参考；最底层、最淡）
    draw_poly(d, FULL_ROUTE, s["canonical"], s["canonical_w"])

    # 2) 已跑规划段（柔和，与 GPS 轨迹融合但偏离诚实可见）
    draw_poly(d, done, s["done"], s["done_w"])

    # 3) 剩余主线：描边 + 渐变核心
    draw_poly(d, remain, s["casing"], s["casing_w"])
    draw_gradient_poly(img, remain, s["core1"], s["core2"], s["core_w"])
    d = ImageDraw.Draw(img, "RGBA")

    # 4) 重规划连接段（琥珀，与原路线明显区分）
    draw_poly(d, REROUTE_SEG, s["reroute_c"], s["reroute_w"] + 4)
    draw_poly(d, REROUTE_SEG, s["reroute"], s["reroute_w"])

    # 5) GPS 真实轨迹（白描边 + 橙核心，压在最上——真实位置绝不被遮盖）
    draw_poly(d, GPS_WOBBLE, s["gps_c"], s["gps_c_w"])
    draw_poly(d, GPS_WOBBLE, s["gps"], s["gps_w"])

    # ---- 方向箭头：直行段稀疏；底部共路段双侧同时可见（6.2） ----
    def arrows_for(leg: List[Pt], color, n: int, offset=(0, 0), filled=None):
        filled = s["arrow_kind"] == "filled" if filled is None else filled
        for k in range(1, n + 1):
            c, ang = point_at(leg, k / (n + 1.0))
            c = (c[0] + offset[0], c[1] + offset[1])
            if s["arrow_kind"] == "filled" or filled:
                draw_arrow_filled(d, c, ang, color)
            else:
                draw_chevron(d, c, ang, color, filled=filled)

    # 去程（西行，底路上侧）与返程（东行，底路下侧）：双侧偏移 + 形/色双编码
    arrows_for(offset_leg(LOOP_WEST, 0, -9), s["arrow_out"], 1, filled=True)
    arrows_for(offset_leg(LOOP_BACK, 0, 9), s["arrow_back"], 1, filled=False)
    arrows_for(LOOP_NORTH, s["arrow_out"], 2)
    arrows_for(LOOP_TOP, s["arrow_out"], 2)
    arrows_for(LOOP_SOUTH, s["arrow_back"], 2)

    # ---- 转弯标注（去=青 / 返=紫 的现有语义保留，样式随方案） ----
    turn_pts = [(170, 1230, 0, "out"), (170, 300, 90, "out"),
                (870, 300, 180, "back"), (870, 1230, 270, "back")]
    for (x, y, ang, kind) in turn_pts:
        col = (0, 121, 107, 255) if kind == "out" else (123, 31, 162, 255)
        if s["turn_style"] == "circle":
            d.ellipse([x - 13, y - 13, x + 13, y + 13],
                      fill=(255, 255, 255, 255), outline=(0, 0, 0, 60), width=2)
            draw_chevron(d, (x, y + 1), ang, col, size=8, width=4)
        else:  # minimal：无圆底，柔和阴影 + 粗圆头人字形
            d.ellipse([x - 9, y - 9, x + 9, y + 9], fill=(255, 255, 255, 200))
            draw_chevron(d, (x, y + 1), ang, col, size=7, width=4)

    # ---- 起点标记 + 图例 ----
    d.ellipse([488, 1218, 512, 1242], fill=(46, 125, 50, 255),
              outline=(255, 255, 255, 255), width=3)
    f_t = font(30)
    f_s = font(21)
    d.rectangle([24, 24, W - 24, 118], fill=(255, 255, 255, 225))
    d.text((44, 36), s["name"] + ("（阳光直射模拟）" if sunlight else ""),
           font=f_t, fill=(33, 33, 33))
    d.text((44, 78), s["desc"], font=f_s, fill=(90, 90, 90))


def main():
    ia = Image.new("RGBA", (W, H))
    draw_scheme(ia, SCHEME_A, sunlight=False)
    ia.convert("RGB").save(os.path.join(OUT, "scheme_a.png"))

    ib = Image.new("RGBA", (W, H))
    draw_scheme(ib, SCHEME_B, sunlight=False)
    ib.convert("RGB").save(os.path.join(OUT, "scheme_b.png"))

    # 并排对比图
    comp = Image.new("RGB", (W * 2 + 40, H + 40), (250, 250, 250))
    comp.paste(ia.convert("RGB"), (10, 30))
    comp.paste(ib.convert("RGB"), (W + 30, 30))
    comp.save(os.path.join(OUT, "compare.png"))

    # 阳光直射对比（高亮低对比底图下的可读性，6.4）
    sa = Image.new("RGBA", (W, H))
    draw_scheme(sa, SCHEME_A, sunlight=True)
    sb = Image.new("RGBA", (W, H))
    draw_scheme(sb, SCHEME_B, sunlight=True)
    sun = Image.new("RGB", (W * 2 + 40, H + 40), (250, 250, 250))
    sun.paste(sa.convert("RGB"), (10, 30))
    sun.paste(sb.convert("RGB"), (W + 30, 30))
    sun.save(os.path.join(OUT, "sunlight.png"))

    print("written:", OUT)
    for f in ("scheme_a.png", "scheme_b.png", "compare.png", "sunlight.png"):
        print(" -", f)


if __name__ == "__main__":
    main()
