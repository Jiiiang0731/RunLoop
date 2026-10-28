#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重复路段识别：检测闭环路线中「同一道路被两次经过（尤其反向）」的区段。

只用于地图「视觉分离」，不修改真实折线、距离、GPS 或偏航计算。
"""
import math
from typing import Dict, List, Tuple

from .geo import GeoPoint, haversine

_M_PER_DEG_LAT = 110574.0


def _mlng(lat: float) -> float:
    return 111320.0 * math.cos(math.radians(lat))


def _bearing(a: GeoPoint, b: GeoPoint) -> float:
    lat1 = math.radians(a[1])
    lat2 = math.radians(b[1])
    dlon = math.radians(b[0] - a[0])
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def detect_overlaps(
    polyline: List[GeoPoint],
    cell_m: float = 25.0,
    index_gap: int = 25,
    match_m: float = 28.0,
    opposite_min_deg: float = 120.0,
    min_edges: int = 4,
) -> List[dict]:
    """返回重复路段的区间组。

    每组形如：
      {"ref_bearing": 45.0,
       "ranges": [{"start": 120, "end": 180, "offset": -1.0, "direction": "forward"},
                  {"start": 300, "end": 360, "offset": 1.0,  "direction": "reverse"}]}
    区间索引对应传入 polyline 的点下标（左闭右开）。
    """
    n = len(polyline)
    if n < 8:
        return []

    lat0 = sum(p[1] for p in polyline) / n
    lng0 = sum(p[0] for p in polyline) / n
    mlng = _mlng(lat0)

    edges = []
    for i in range(n - 1):
        a, b = polyline[i], polyline[i + 1]
        if a == b:
            continue
        mx = (a[0] + b[0]) / 2 - lng0
        my = (a[1] + b[1]) / 2 - lat0
        edges.append({
            "i": i,
            "x": mx * mlng,
            "y": my * _M_PER_DEG_LAT,
            "brg": _bearing(a, b),
            "len": haversine(a, b),
        })
    if not edges:
        return []

    grid: Dict[Tuple[int, int], List[dict]] = {}
    for e in edges:
        key = (int(e["x"] // cell_m), int(e["y"] // cell_m))
        grid.setdefault(key, []).append(e)

    # 标记重叠边（反向经过为主，兼顾同向重复）
    overlap_edges: Dict[int, int] = {}  # 边下标 -> 组内方向(0 正向 / 1 反向)
    pairs: List[Tuple[int, int]] = []
    for e in edges:
        gx, gy = int(e["x"] // cell_m), int(e["y"] // cell_m)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for o in grid.get((gx + dx, gy + dy), []):
                    if abs(o["i"] - e["i"]) < index_gap:
                        continue
                    dist = math.hypot(o["x"] - e["x"], o["y"] - e["y"])
                    if dist > match_m:
                        continue
                    diff = abs(((o["brg"] - e["brg"] + 540) % 360) - 180)  # 0..180
                    # 反向（diff 接近 180）或同向重复（diff 接近 0）均视为重叠
                    if diff >= opposite_min_deg:
                        pairs.append((e["i"], o["i"]))
                    elif diff <= 20.0:
                        pairs.append((e["i"], o["i"]))

    if not pairs:
        return []

    # 按边下标分组：相邻的重叠边合并为区间
    pair_set = set()
    for a, b in pairs:
        pair_set.add(a)
        pair_set.add(b)
    ordered = sorted(pair_set)

    ranges: List[dict] = []
    cur_start = ordered[0]
    prev = ordered[0]
    for idx in ordered[1:]:
        if idx - prev <= 1:
            prev = idx
            continue
        ranges.append({"start": cur_start, "end": prev + 1})
        cur_start = idx
        prev = idx
    ranges.append({"start": cur_start, "end": prev + 1})

    # 只保留足够长的区间（过滤噪声）
    ranges = [r for r in ranges if (r["end"] - r["start"]) >= min_edges]
    if not ranges:
        return []

    # 把区间两两配对：按顺序，前一半与后一半配对（同一条路去/返）
    # 简化策略：每两个相邻区间组成一组
    groups: List[dict] = []
    i = 0
    while i + 1 < len(ranges) + 1:
        if i + 1 < len(ranges):
            r1, r2 = ranges[i], ranges[i + 1]
            mid = polyline[min((r1["start"] + r1["end"]) // 2, n - 1)]
            brg = _bearing(polyline[min(r1["start"], n - 2)], polyline[min(r1["start"] + 1, n - 1)])
            groups.append({
                "ref_bearing": round(brg, 1),
                "ranges": [
                    {"start": r1["start"], "end": r1["end"], "offset": -1.0},
                    {"start": r2["start"], "end": r2["end"], "offset": 1.0},
                ],
            })
            i += 2
        else:
            i += 1
    return groups
