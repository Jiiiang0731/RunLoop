#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路线评分：面向跑步体验的五维加权（转弯/直行/重复/急弯/距离贴合）。

硬约束（距离容差、闭合误差、分段有效性）不参与加权，由调用方单独判定；
本模块只负责「在合格候选中排序」。
"""
import math
from typing import Dict, List, Optional

from .geo import haversine
from .types import LoopRoute, ScoreComponent, ScoreResult

# 权重（阶段 N）：距离贴合升为第一权重——用户规范「±500m 是最大容差，
# 不是允许随意使用的误差额度」；转弯/直行/重复/急弯保持质量约束作用。
DEFAULT_WEIGHTS: Dict[str, float] = {
    "distance_fit": 0.35,
    "turn_density": 0.30,
    "long_straight": 0.15,
    "repetition": 0.15,
    "sharp_short": 0.05,
}

# 距离评分曲线（相对目标，阶段 N）：1km→20m 满分/100m 归零；
# 5km→50m/500m；50km→500m/5000m（此时 ±500m 硬上限本身更严）。
DIST_FULL_ABS_M = 20.0
DIST_FULL_RATIO = 0.01
DIST_ZERO_ABS_M = 60.0
DIST_ZERO_RATIO = 0.10


def distance_error_score(err_m: float, target_m: Optional[float] = None) -> float:
    """距离误差评分（阶段 N：以用户目标为中心的相对曲线）。

    旧实现「±300m 内满分」让 1km 差 400m 与差 30m 几乎等价，被用户明确
    否决。新曲线：满分带宽 = max(20m, 1%·目标)，归零点 = max(60m, 10%·目标)，
    中间线性——误差越接近目标得分越高，绝不饱和。
    `target_m=None` 时退回旧的绝对曲线（兼容历史调用）。
    """
    a = abs(err_m)
    if target_m is None or target_m <= 0:
        if a <= 300:
            return 100.0
        if a >= 2300:
            return 0.0
        return round(100.0 * (1 - (a - 300) / 2000.0), 1)
    t = float(target_m)
    full = max(DIST_FULL_ABS_M, DIST_FULL_RATIO * t)
    zero = max(DIST_ZERO_ABS_M, DIST_ZERO_RATIO * t)
    if zero <= full:
        zero = full + 1.0
    if a <= full:
        return 100.0
    if a >= zero:
        return 0.0
    return round(100.0 * (1 - (a - full) / (zero - full)), 1)


def closure_score(closure_m: float) -> float:
    """闭合误差评分：≤5m 满分，5→100m 线性衰减到 0。"""
    if closure_m <= 5:
        return 100.0
    if closure_m >= 100:
        return 0.0
    return round(100.0 * (1 - (closure_m - 5) / 95.0), 1)


def turn_density_score(density: float) -> float:
    """每公里有效转弯数：≤0.3 满分，≥2.0 为 0（线性）。"""
    if density <= 0.3:
        return 100.0
    if density >= 2.0:
        return 0.0
    return round(100.0 * (1 - (density - 0.3) / 1.7), 1)


def long_straight_score(metrics: Dict) -> float:
    """>300m 直行占比（60%）+ 平均直行长度（40%）。"""
    ratio = float(metrics.get("straight_ratio_300", 0.0))
    avg = float(metrics.get("straight_avg_m", 0.0))
    s1 = min(1.0, ratio / 0.6) * 100.0
    s2 = min(1.0, avg / 600.0) * 100.0
    return round(0.6 * s1 + 0.4 * s2, 1)


def sharp_short_score(metrics: Dict) -> float:
    """急弯、短距离连续转弯、掉头越少越高。

    P1：分段接缝处的短折返（跑出去十几米又原路折回）额外重罚——它既浪费
    距离，又会让语音连续报「掉头」，是真实测试中最刺眼的体验问题。
    """
    sharp = int(metrics.get("sharp_turns", 0))
    short = int(metrics.get("short_consecutive", 0))
    uturn = int(metrics.get("uturns", 0))
    join_short = int(metrics.get("join_short_uturns", 0))
    penalty = sharp * 8 + short * 12 + uturn * 10 + join_short * 25
    return round(max(0.0, 100.0 - penalty), 1)


def repetition_ratio(polyline: List, bin_m: float = 50.0) -> float:
    """重复路段占比（网格分箱近似）：重复走过的距离 / 总距离，0=无重复。"""
    if len(polyline) < 2:
        return 0.0
    lat = sum(p[1] for p in polyline) / len(polyline)
    mperlng = 111320.0 * math.cos(math.radians(lat))
    mperlat = 110574.0
    visited = set()
    total = 0.0
    repeated = 0.0
    for i in range(len(polyline) - 1):
        a, b = polyline[i], polyline[i + 1]
        seg = haversine(a, b)
        if seg <= 0:
            continue
        total += seg
        n = max(1, int(round(seg / (2 * bin_m))))
        for k in range(n):
            t = (k + 0.5) / n
            mx = a[0] + (b[0] - a[0]) * t
            my = a[1] + (b[1] - a[1]) * t
            key = (int(mx * mperlng / bin_m), int(my * mperlat / bin_m))
            if key in visited:
                repeated += seg / n
            visited.add(key)
    return min(1.0, repeated / total if total > 0 else 0.0)


def repetition_score(ratio: float) -> float:
    """重复路段评分：≤2% 满分，2%→50% 线性衰减到 0。"""
    if ratio <= 0.02:
        return 100.0
    if ratio >= 0.5:
        return 0.0
    return round(100.0 * (1 - (ratio - 0.02) / 0.48), 1)


def score_route(target_m: int, loop: LoopRoute,
                metrics: Optional[Dict] = None,
                weights: Optional[Dict[str, float]] = None) -> ScoreResult:
    """聚合评分：五维加权；闭合作为硬约束单独列出（权重 0）。"""
    w = weights or DEFAULT_WEIGHTS
    m = metrics or {}
    components: List[ScoreComponent] = []

    err = loop.distance_m - target_m
    components.append(ScoreComponent(
        "turn_density",
        turn_density_score(float(m.get("turn_density", 2.0))),
        w.get("turn_density", 0), True,
        f"{int(m.get('turns', 0))} 次转弯 / {float(m.get('turn_density', 0)):.2f} 次/公里"))
    components.append(ScoreComponent(
        "long_straight", long_straight_score(m), w.get("long_straight", 0), True,
        f"最长直行 {float(m.get('straight_max_m', 0)):.0f}m，>300m 占比 {float(m.get('straight_ratio_300', 0)):.0%}"))
    components.append(ScoreComponent(
        "repetition", repetition_score(float(m.get("repetition_ratio", 0.0))),
        w.get("repetition", 0), True,
        f"重复路段 {float(m.get('repetition_ratio', 0)):.1%}"))
    components.append(ScoreComponent(
        "sharp_short", sharp_short_score(m), w.get("sharp_short", 0), True,
        f"急弯 {int(m.get('sharp_turns', 0))}，短连弯 {int(m.get('short_consecutive', 0))}，"
        f"接缝短折返 {int(m.get('join_short_uturns', 0))}"))
    components.append(ScoreComponent(
        "distance_fit", distance_error_score(err, target_m), w.get("distance_fit", 0), True,
        f"误差 {err:+.0f}m（目标 {target_m}m）"))
    # 硬约束：不计入加权，仅展示
    components.append(ScoreComponent(
        "closure", closure_score(loop.closure_m), 0.0, True, f"闭合 {loop.closure_m}m"))

    s = 0.0
    wsum = 0.0
    for c in components:
        if c.available and c.score is not None and c.weight > 0:
            s += c.score * c.weight
            wsum += c.weight
    total = round(s / wsum, 1) if wsum > 0 else 0.0
    return ScoreResult(total=total, components=components, unavailable=[])
