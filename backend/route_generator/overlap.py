#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重复路段识别 v2（阶段 K）：检测闭环路线中「同一道路被两次经过」的区段。

与 v1（按区间顺序两两配对，交叉口处会把两条不同的路错配）不同，v2 做
**真实空间配对**：
1. 网格哈希找出所有「空间距离 ≤ match_m 且反向/同向平行」的边对（保留配对链接）；
2. 重叠边按连续性聚成 run，并在转角 > 60° 处切分（路口处两条路各成子段）；
3. 子段之间按「配对链接的落点分布」互相认领（多数票），每个子段只配一次；
4. 每组输出 pass 1（先经过）/ pass 2（后经过）+ 累计里程区间 + 方向关系。

仅用于地图标注与视觉提示（去/返两侧标记），不修改真实折线、距离、GPS
或偏航计算（阶段 K 规范：标注永远是视觉层）。

输出（每组）：
  {"ref_bearing": 45.0,                 # pass1 首边方位角（度）
   "direction": "reverse"|"forward",    # 两次经过的方向关系
   "ranges": [ {"start": i, "end": j, "offset": -1.0},   # v1 兼容（点下标，左闭右开）
               {"start": k, "end": l, "offset": +1.0} ],
   "passes": [ {"pass": 1, "start": i, "end": j, "cum_start_m": x, "cum_end_m": y},
               {"pass": 2, "start": k, "end": l, "cum_start_m": x2, "cum_end_m": y2} ]}
"""
import math
from typing import Dict, List, Optional, Tuple

from .geo import GeoPoint, haversine

_M_PER_DEG_LAT = 110574.0
_CORNER_SPLIT_DEG = 60.0


def _mlng(lat: float) -> float:
    return 111320.0 * math.cos(math.radians(lat))


def _bearing(a: GeoPoint, b: GeoPoint) -> float:
    lat1 = math.radians(a[1])
    lat2 = math.radians(b[1])
    dlon = math.radians(b[0] - a[0])
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def _ang_diff(a: float, b: float) -> float:
    """两方位角夹角 0..180。"""
    return abs(((a - b + 540) % 360) - 180)


def _cumulative(polyline: List[GeoPoint]) -> List[float]:
    cum = [0.0]
    for i in range(1, len(polyline)):
        cum.append(cum[-1] + haversine(polyline[i - 1], polyline[i]))
    return cum


def detect_overlaps(
    polyline: List[GeoPoint],
    cell_m: float = 25.0,
    index_gap: int = 25,
    match_m: float = 28.0,
    opposite_min_deg: float = 120.0,
    min_edges: int = 4,
) -> List[dict]:
    """返回重复路段组（真实空间配对，含 pass 序号与累计里程）。

    参数与 v1 兼容：cell_m 网格边长、index_gap 最小边下标间隔（防紧转角自配）、
    match_m 空间匹配半径、opposite_min_deg 反向判定角、min_edges 子段最少边数。
    """
    n = len(polyline)
    if n < 8:
        return []

    lat0 = sum(p[1] for p in polyline) / n
    lng0 = sum(p[0] for p in polyline) / n
    mlng = _mlng(lat0)

    edges: List[Optional[dict]] = [None] * (n - 1)
    edge_list: List[dict] = []
    for i in range(n - 1):
        a, b = polyline[i], polyline[i + 1]
        if a == b:
            continue
        e = {
            "i": i,
            "x": ((a[0] + b[0]) / 2 - lng0) * mlng,
            "y": ((a[1] + b[1]) / 2 - lat0) * _M_PER_DEG_LAT,
            "brg": _bearing(a, b),
        }
        edges[i] = e
        edge_list.append(e)
    if not edge_list:
        return []

    grid: Dict[Tuple[int, int], List[dict]] = {}
    for e in edge_list:
        grid.setdefault((int(e["x"] // cell_m), int(e["y"] // cell_m)), []).append(e)

    # ---- 1) 配对链接：adj[i] = [(j, ang_diff), ...] ----
    adj: Dict[int, List[Tuple[int, float]]] = {}
    for e in edge_list:
        gx, gy = int(e["x"] // cell_m), int(e["y"] // cell_m)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for o in grid.get((gx + dx, gy + dy), []):
                    if o["i"] == e["i"] or abs(o["i"] - e["i"]) < index_gap:
                        continue
                    if math.hypot(o["x"] - e["x"], o["y"] - e["y"]) > match_m:
                        continue
                    diff = _ang_diff(o["brg"], e["brg"])  # 0=同向, 180=反向
                    # 反向（≥opposite_min_deg）或同向重复（≤20°）均视为重叠
                    if diff >= opposite_min_deg or diff <= 20.0:
                        adj.setdefault(e["i"], []).append((o["i"], diff))
    if not adj:
        return []

    # ---- 2) 重叠边 run + 转角切分成子段 ----
    overlap_idx = sorted(adj.keys())
    runs: List[List[int]] = []
    cur = [overlap_idx[0]]
    for idx in overlap_idx[1:]:
        if idx - cur[-1] == 1:
            cur.append(idx)
        else:
            runs.append(cur)
            cur = [idx]
    runs.append(cur)

    subruns: List[List[int]] = []
    for run in runs:
        seg = [run[0]]
        for prev_i, i in zip(run[:-1], run[1:]):
            ep, ec = edges[prev_i], edges[i]
            if ep is None or ec is None or _ang_diff(ep["brg"], ec["brg"]) > _CORNER_SPLIT_DEG:
                subruns.append(seg)
                seg = [i]
            else:
                seg.append(i)
        subruns.append(seg)
    subruns = [s for s in subruns if len(s) >= min_edges]
    if len(subruns) < 2:
        return []

    # 边下标 → 子段号
    sub_of: Dict[int, int] = {}
    for si, s in enumerate(subruns):
        for i in s:
            sub_of[i] = si

    # ---- 3) 子段互相认领（配对链接多数票），每子段只配一次 ----
    votes: Dict[Tuple[int, int], List[float]] = {}
    for i, links in adj.items():
        si = sub_of.get(i)
        if si is None:
            continue
        for j, diff in links:
            sj = sub_of.get(j)
            if sj is None or sj == si:
                continue
            key = (min(si, sj), max(si, sj))
            votes.setdefault(key, []).append(diff)

    ranked = sorted(votes.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    used: set = set()
    groups: List[dict] = []
    cum = _cumulative(polyline)
    for (sa, sb), diffs in ranked:
        if sa in used or sb in used:
            continue
        used.add(sa)
        used.add(sb)
        A, B = subruns[sa], subruns[sb]
        # pass 1 = 先经过（边下标更小）
        first, second = (A, B) if A[0] < B[0] else (B, A)
        median_diff = sorted(diffs)[len(diffs) // 2]
        direction = "reverse" if median_diff >= opposite_min_deg else "forward"
        e0 = edges[first[0]]
        ref_bearing = e0["brg"] if e0 is not None else 0.0
        groups.append({
            "ref_bearing": round(ref_bearing, 1),
            "direction": direction,
            "ranges": [
                {"start": first[0], "end": first[-1] + 1, "offset": -1.0},
                {"start": second[0], "end": second[-1] + 1, "offset": +1.0},
            ],
            "passes": [
                {"pass": 1, "start": first[0], "end": first[-1] + 1,
                 "cum_start_m": round(cum[first[0]], 1),
                 "cum_end_m": round(cum[first[-1] + 1], 1)},
                {"pass": 2, "start": second[0], "end": second[-1] + 1,
                 "cum_start_m": round(cum[second[0]], 1),
                 "cum_end_m": round(cum[second[-1] + 1], 1)},
            ],
        })
    groups.sort(key=lambda g: g["passes"][0]["start"])
    return groups
