#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：锚点闭环（用户参考锚点 → 真实道路闭环 → 按目标裁剪）。

动机（实测）：校园 2.5km 环线是一条约 2987m 的干净闭环，但它的中心比
起点偏移约 450m，同心圆/矩形骨架无论怎么调参都无法同时命中距离与质量
（骨架法实测 2839m/转弯 20 次）。锚点法直接沿真实道路走，质量由路网决定。

铁律：
- 相邻锚点之间**必须**用真实规划（不是直线连接）；
- 裁剪只通过「去掉拐点」实现，绝不插入虚假折返凑距离；
- 返回的候选带真实距离、转弯数、逐段道路与是否命中目标，
  距离不达标时如实上报，不做假。
"""
from typing import Dict, List, Optional

from .geo import GeoPoint, haversine
from .nav_metrics import analyze_route
from .planner import MapPlanner
from .types import LoopRoute, PlanStep, RouteSegment


def _build(planner: MapPlanner, seq: List[GeoPoint]) -> Optional[LoopRoute]:
    """按给定有序点列逐段真实规划成闭环（末点回到首点）。"""
    allpts: List[GeoPoint] = []
    segs: List[RouteSegment] = []
    total = 0.0
    dur = 0.0
    for i in range(len(seq) - 1):
        r = planner.plan_walking(seq[i], seq[i + 1])
        if r.error or not r.points:
            return None
        total += r.distance_m
        dur += r.duration_s
        pts = list(r.points)
        if allpts:
            allpts.extend(pts[1:] if len(pts) > 1 else pts)
        else:
            allpts.extend(pts)
        segs.append(RouteSegment(index=i, origin=seq[i], destination=seq[i + 1],
                                 distance_m=r.distance_m, duration_s=r.duration_s,
                                 n_points=len(pts), steps=r.steps))
    if len(allpts) < 2:
        return None
    return LoopRoute(distance_m=total, duration_s=dur,
                     closure_m=round(haversine(allpts[0], allpts[-1]), 2),
                     start_snap_m=round(haversine(seq[0], allpts[0]), 2),
                     polyline=allpts, segments=segs)


def build_anchor_loop(planner: MapPlanner,
                      anchors: List[GeoPoint],
                      target_m: int,
                      tol_m: float = 500.0,
                      max_drop_tries: int = 4) -> Dict:
    """锚点闭环 + 单拐点裁剪。

    返回 {ok, loop, anchors_used, error, candidates:[{drop, distance, err, turns}]}
    """
    if len(anchors) < 4:
        return {"ok": False, "error": "锚点少于 4 个，无法构成闭环"}
    seq = list(anchors) + [anchors[0]]
    base = _build(planner, seq)
    if base is None:
        return {"ok": False, "error": "锚点之间存在不可达路段"}

    def evaluate(loop: LoopRoute, drop: int) -> Dict:
        steps: List[PlanStep] = [s for seg in loop.segments for s in seg.steps]
        m = analyze_route(steps, loop.polyline, target_m)
        return {"drop": drop, "distance": round(loop.distance_m, 1),
                "err": round(loop.distance_m - target_m, 1),
                "turns": m.get("turns"), "density": m.get("turn_density"),
                "rep": m.get("repetition_ratio"),
                "walk_bad": m.get("walk_bad_ratio"), "loop": loop}

    cands: List[Dict] = [evaluate(base, -1)]
    # 只裁「能减距离」的拐点：逐点尝试去掉一个锚点（预算内）
    if abs(base.distance_m - target_m) > tol_m:
        order = sorted(range(len(anchors)), key=lambda i: i)
        for drop in order[:max_drop_tries]:
            keep = [p for i, p in enumerate(anchors) if i != drop]
            if len(keep) < 3:
                continue
            loop = _build(planner, keep + [keep[0]])
            if loop is not None:
                cands.append(evaluate(loop, drop))

    best = min(cands, key=lambda c: abs(c["err"]))
    ok = abs(best["err"]) <= tol_m
    return {"ok": ok, "loop": best["loop"], "anchors_used": len(anchors),
            "best": best, "candidates": [{k: v for k, v in c.items() if k != "loop"}
                                         for c in cands],
            "error": None if ok else "锚点闭环距离仍超出容差（如实返回，不凑数）"}
