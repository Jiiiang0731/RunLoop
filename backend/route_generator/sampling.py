#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""沿路线累计距离采样（用于按里程查询沿途地标）。"""
from typing import List, Tuple

from .geo import GeoPoint, haversine


def sample_points_by_distance(
    polyline: List[GeoPoint],
    interval_m: float = 1000.0,
    max_points: int = 18,
) -> List[Tuple[GeoPoint, float]]:
    """沿折线按累计距离采样。

    返回 [(point, cumulative_m), ...]，按行进顺序排列。
    每个采样点的累计距离 >= 对应 interval 的整数倍。
    """
    if len(polyline) < 2 or interval_m <= 0:
        return []
    out: List[Tuple[GeoPoint, float]] = []
    cumulative = 0.0
    next_target = interval_m
    for i in range(1, len(polyline)):
        cumulative += haversine(polyline[i - 1], polyline[i])
        while cumulative >= next_target and len(out) < max_points:
            out.append((polyline[i], round(cumulative, 1)))
            next_target += interval_m
    if not out:
        mid = len(polyline) // 2
        out.append((polyline[mid], round(cumulative, 1)))
    return out
