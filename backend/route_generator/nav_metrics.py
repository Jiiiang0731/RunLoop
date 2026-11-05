#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路线质量指标：真实转弯、转弯密度、急弯、短距离连续转弯、连续直行、重复比例。

说明：
- 转弯优先由「相邻 step 的真实行进方向」推导，而不是数 polyline 的每个相邻点。
- 几何简化只用于分析/评分，不覆盖真实导航折线。
"""
import math
from typing import Dict, List, Optional

from .geo import GeoPoint, haversine
from .nav_text import bearing, turn_kind
from .quality import walk_type_profile
from .scorer import repetition_ratio
from .types import PlanStep

# 无 action 时的几何兜底：只算明显转弯（度）
_MIN_TURN_DEG = 45.0
# 急弯阈值（度）
_SHARP_TURN_DEG = 100.0
# 短距离连续转弯的间距阈值（米）
_SHORT_TURN_GAP_M = 50.0
# 直行路段阈值（米）
_STRAIGHT_THRESHOLDS = (200.0, 300.0, 500.0)

# 阶段 N：walk_type 的取值解释集中在 quality.py。这里只消费已确认类型，
# 未收录取值（如实测 20）不猜测、不参与「非地面路段」比例。


def _polyline_length(pts: List[GeoPoint]) -> float:
    total = 0.0
    for i in range(1, len(pts)):
        total += haversine(pts[i - 1], pts[i])
    return total


def _median(values: List[float]) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 == 1 else (s[mid - 1] + s[mid]) / 2.0


def _is_turn_action(action: str) -> bool:
    """AMap 的行走动作里，只有真正的左转/右转/掉头才算「有效转弯」。

    「向左前方行走 / 向右前方行走」属于道路弯曲，不是路口转弯，不计入。
    """
    a = (action or "").strip()
    if not a:
        return False
    if "掉头" in a:
        return True
    return ("左转" in a) or ("右转" in a)


def _turn_kind_from_action(action: str, angle_deg: float) -> str:
    a = (action or "").strip()
    if "掉头" in a:
        return "uturn"
    if "左转" in a:
        return "left"
    if "右转" in a:
        return "right"
    return "right" if angle_deg >= 0 else "left"


def _turns_from_actions(steps: List[PlanStep]) -> List[Dict]:
    """优先用 AMap 的 action 判定真实转弯（避免把道路弯曲/采样抖动误判为转弯）。"""
    turns: List[Dict] = []
    segs = [s for s in steps if s.polyline and len(s.polyline) >= 2]
    cumulative = 0.0
    for i, st in enumerate(segs):
        cumulative += _polyline_length(st.polyline)
        action = st.action or ""
        if not _is_turn_action(action):
            continue
        angle = 0.0
        if i + 1 < len(segs):
            exit_b = bearing(st.polyline[-2], st.polyline[-1])
            enter_b = bearing(segs[i + 1].polyline[0], segs[i + 1].polyline[1])
            angle = abs((enter_b - exit_b + 540) % 360 - 180)
        turns.append({
            "at_m": round(cumulative, 1),
            "angle": round(angle, 1),
            "kind": _turn_kind_from_action(action, angle),
        })
    return turns


def _turns_from_geometry(steps: List[PlanStep]) -> List[Dict]:
    """兜底：steps 缺少 action 时，用几何方向判断（阈值较高，只算明显转弯）。"""
    turns: List[Dict] = []
    cumulative = 0.0
    prev_exit: Optional[float] = None
    for st in steps:
        if not st.polyline or len(st.polyline) < 2:
            continue
        enter_b = bearing(st.polyline[0], st.polyline[1])
        exit_b = bearing(st.polyline[-2], st.polyline[-1])
        if prev_exit is not None:
            d = (enter_b - prev_exit + 540) % 360 - 180
            if abs(d) >= _MIN_TURN_DEG:
                turns.append({
                    "at_m": round(cumulative, 1),
                    "angle": round(abs(d), 1),
                    "kind": "right" if d > 0 else "left",
                })
        cumulative += _polyline_length(st.polyline)
        prev_exit = exit_b
    return turns


def detect_turns(steps: List[PlanStep]) -> List[Dict]:
    """返回真实转弯列表：[{at_m, angle, kind}]，at_m 为该转弯处的累计道路距离。"""
    has_action = any((s.action or "").strip() for s in steps)
    return _turns_from_actions(steps) if has_action else _turns_from_geometry(steps)


def _straight_runs(turns: List[Dict], total_m: float) -> List[float]:
    """相邻转弯之间的直行路段长度（含起点→首弯、末弯→终点）。"""
    if total_m <= 0:
        return []
    if not turns:
        return [total_m]
    runs: List[float] = []
    prev = 0.0
    for t in turns:
        runs.append(max(0.0, t["at_m"] - prev))
        prev = t["at_m"]
    runs.append(max(0.0, total_m - prev))
    return runs


def analyze_route(steps: List[PlanStep], polyline: List[GeoPoint],
                  target_m: int) -> Dict:
    """计算路线的跑步友好指标（真实数据推导）。"""
    total_m = _polyline_length(polyline) if polyline else sum(
        _polyline_length(s.polyline) for s in steps if s.polyline)
    turns = detect_turns(steps)
    n_turns = len(turns)
    km = max(total_m / 1000.0, 0.001)
    sharp = [t for t in turns if t["angle"] >= _SHARP_TURN_DEG]
    uturns = [t for t in turns if t["angle"] >= 150.0]
    # 短距离连续转弯：相邻两次有效转弯间隔 < 阈值
    short_pairs = 0
    for i in range(1, len(turns)):
        if turns[i]["at_m"] - turns[i - 1]["at_m"] < _SHORT_TURN_GAP_M:
            short_pairs += 1

    runs = _straight_runs(turns, total_m)
    run_sum = sum(runs) if runs else 0.0
    ratios = {}
    for th in _STRAIGHT_THRESHOLDS:
        if run_sum > 0:
            ratios[th] = round(sum(r for r in runs if r >= th) / run_sum, 3)
        else:
            ratios[th] = 0.0

    # 阶段 N：真实 walk_type 统计（只解释已确认取值；未知值单列 unclassified）
    profile = walk_type_profile(steps, total_m)

    return {
        "total_m": round(total_m, 1),
        "turns": n_turns,
        "turn_density": round(n_turns / km, 2),
        "sharp_turns": len(sharp),
        "uturns": len(uturns),
        "short_consecutive": short_pairs,
        "straight_avg_m": round(run_sum / len(runs), 1) if runs else 0.0,
        "straight_median_m": round(_median(runs), 1),
        "straight_max_m": round(max(runs), 1) if runs else 0.0,
        "straight_ratio_200": ratios[200.0],
        "straight_ratio_300": ratios[300.0],
        "straight_ratio_500": ratios[500.0],
        "repetition_ratio": round(repetition_ratio(polyline), 3),
        # 兼容旧字段：已确认的非地面类型距离占比（不是安全分）
        "walk_bad_ratio": profile["grade_separated_ratio"],
        "walk_types": profile["counts"],
        "walk_type_profile": profile,
        "target_m": target_m,
    }
