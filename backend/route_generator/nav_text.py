#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导航文字生成：从真实 steps 与几何推导转向，合并碎步，输出跑者能读懂的说明。

设计原则：
- 不依赖「向东北步行 140 米」这类方位词；转向由相邻段的真实方位角推导。
- 合并「自身直行且很短」的碎步，只保留真实路口与转弯。
- 每条指令带累计里程与段长，便于 App 计算「距离下一个转弯」。
"""
import math
from typing import List

from .geo import GeoPoint
from .types import PlanStep

# 碎步阈值（米）：自身直行且短于此值的段并入上一段
_SHORT_STEP_M = 40.0
# 自身「直行」的方位角容差（度）
_STRAIGHT_TOL = 30.0


def bearing(a: GeoPoint, b: GeoPoint) -> float:
    """a→b 的方位角（0=正北，顺时针，0~360）。"""
    lat1 = math.radians(a[1])
    lat2 = math.radians(b[1])
    dlon = math.radians(b[0] - a[0])
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def _ang_diff(a: float, b: float) -> float:
    return abs((b - a + 540) % 360 - 180)


def turn_kind(enter_b: float, exit_b: float) -> str:
    """根据进入/离开方位角判断转向。"""
    d = (exit_b - enter_b + 540) % 360 - 180
    if abs(d) < 25:
        return "straight"
    if abs(d) > 150:
        return "uturn"
    return "right" if d > 0 else "left"


def _step_bearings(pts: List[GeoPoint]):
    if len(pts) < 2:
        return None, None
    return bearing(pts[0], pts[1]), bearing(pts[-2], pts[-1])


def _fmt_dist(m: float) -> str:
    if m >= 1000:
        return f"{m / 1000:.1f} 公里"
    return f"{int(round(m))} 米"


def build_nav_instructions(steps: List[PlanStep]) -> List[dict]:
    """把原始 steps 转成自然语言导航列表。

    返回每项：cumulative_m / distance_m / road / turn / text / junction。
    """
    items = []
    for st in steps:
        if not st.polyline or len(st.polyline) < 2:
            continue
        enter_b, exit_b = _step_bearings(st.polyline)
        items.append({
            "road": (st.road or "").strip(),
            "distance_m": float(st.distance_m),
            "enter_b": enter_b,
            "exit_b": exit_b,
            "start": st.polyline[0],
            "end": st.polyline[-1],
        })
    if not items:
        return []

    # 合并「自身直行且很短」的碎步到上一段（累加距离，更新终点与出口方位）
    merged = []
    for it in items:
        if merged:
            prev = merged[-1]
            self_straight = _ang_diff(it["enter_b"], it["exit_b"]) < _STRAIGHT_TOL
            if it["distance_m"] < _SHORT_STEP_M and self_straight:
                prev["distance_m"] += it["distance_m"]
                prev["end"] = it["end"]
                prev["exit_b"] = it["exit_b"]
                continue
        merged.append(dict(it))

    # 合并后重新计算每个段末的转向
    for i in range(len(merged)):
        if i + 1 < len(merged):
            merged[i]["turn"] = turn_kind(merged[i]["exit_b"], merged[i + 1]["enter_b"])
        else:
            merged[i]["turn"] = "end"

    out = []
    cumulative = 0.0
    for idx, it in enumerate(merged):
        cumulative += it["distance_m"]
        road = it["road"]
        dist = _fmt_dist(it["distance_m"])
        turn = it["turn"]
        lead = "从起点出发，" if idx == 0 else "继续"
        road_part = f"沿{road}" if road else "沿当前道路"
        tail = {
            "end": "，到达起点（本圈结束）",
            "uturn": "，然后掉头沿原路返回",
            "left": "，然后前方路口左转",
            "right": "，然后前方路口右转",
        }.get(turn, "")
        out.append({
            "cumulative_m": round(cumulative, 1),
            "distance_m": round(it["distance_m"], 1),
            "road": road,
            "turn": turn,
            "text": f"{lead}{road_part}跑约 {dist}{tail}",
            "junction": [round(it["end"][0], 6), round(it["end"][1], 6)],
        })
    return out
