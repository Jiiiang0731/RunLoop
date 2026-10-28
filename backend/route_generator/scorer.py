#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路线评分：各项指标独立成函数，聚合时只计入有可靠数据的维度。

原则：没有可靠数据源的维度不参与评分，但会明确列出（不伪造数值）。
"""
import math
from typing import Dict, List, Optional

from .geo import haversine
from .types import LoopRoute, ScoreComponent, ScoreResult

# 各维度权重（可调整）。标注为“暂无数据”的维度当前不参与聚合。
DEFAULT_WEIGHTS: Dict[str, float] = {
    "distance_error": 0.35,   # 距离误差（有数据）
    "closure": 0.15,          # 起终点闭合（有数据）
    "repetition": 0.25,       # 重复路段占比（有数据，近似）
    "park_greenway": 0.15,    # 公园/绿道覆盖（暂无数据）
    "road_safety": 0.10,      # 主干道占比/安全（暂无数据）
}


def distance_error_score(err_m: float) -> float:
    """距离误差评分：±300m 内满分，300→2300m 线性衰减到 0。"""
    a = abs(err_m)
    if a <= 300:
        return 100.0
    if a >= 2300:
        return 0.0
    return round(100.0 * (1 - (a - 300) / 2000.0), 1)


def closure_score(closure_m: float) -> float:
    """闭合误差评分：≤5m 满分，5→100m 线性衰减到 0。"""
    if closure_m <= 5:
        return 100.0
    if closure_m >= 100:
        return 0.0
    return round(100.0 * (1 - (closure_m - 5) / 95.0), 1)


def repetition_ratio(polyline: List, bin_m: float = 50.0) -> float:
    """重复路段占比（网格分箱近似）：重复走过的距离 / 总距离，0=无重复。

    说明：把折线按约 2*bin_m（约 100m）划分子区间，用子区间中点分箱；
    落在“已访问网格”的子区间长度记为“重复”。这是工程近似指标，用于相对比较，
    不是精确的道路重合计算。
    """
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
            t = (k + 0.5) / n   # 子区间中点
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
                weights: Optional[Dict[str, float]] = None) -> ScoreResult:
    """聚合评分：只对 available 且 score 非 None 的维度加权求和。"""
    w = weights or DEFAULT_WEIGHTS
    components: List[ScoreComponent] = []

    err = loop.distance_m - target_m
    components.append(ScoreComponent(
        "distance_error", distance_error_score(err), w.get("distance_error", 0),
        True, f"误差 {err:+.0f}m"))
    components.append(ScoreComponent(
        "closure", closure_score(loop.closure_m), w.get("closure", 0),
        True, f"闭合 {loop.closure_m}m"))
    ratio = repetition_ratio(loop.polyline)
    components.append(ScoreComponent(
        "repetition", repetition_score(ratio), w.get("repetition", 0),
        True, f"重复路段 {ratio:.1%}"))

    # 暂无可靠数据源的维度：不参与评分，但明确列出
    unavailable: List[str] = []
    for name in ("park_greenway", "road_safety"):
        components.append(ScoreComponent(name, None, w.get(name, 0), False, "暂无可靠数据源"))
        unavailable.append(name)

    s = 0.0
    wsum = 0.0
    for c in components:
        if c.available and c.score is not None:
            s += c.score * c.weight
            wsum += c.weight
    total = round(s / wsum, 1) if wsum > 0 else 0.0
    return ScoreResult(total=total, components=components, unavailable=unavailable)
