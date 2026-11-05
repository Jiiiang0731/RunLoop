#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：锚点闭环（用户参考锚点 → 真实道路闭环 → 按目标裁剪）。

动机（实测）：校园 2.5km 环线是一条约 2987m 的干净闭环，但它的中心比
起点偏移约 450m，同心圆/矩形骨架无论怎么调参都无法同时命中距离与质量
（骨架法实测 2839m/转弯 20 次）。锚点法直接沿真实道路走，质量由路网决定。

铁律：
- 相邻锚点之间**必须**用真实规划（不是直线连接）；
- 裁剪只通过「去掉 1~3 个内部拐点后重新真实规划并闭合到首锚点」实现，
  **绝不切割折线**；任何闭合缺口超过 closure_tol_m 的候选直接作废；
- 首锚点是用户起点，任何裁剪都不得丢掉首锚点；
- 返回的候选带真实距离、转弯数、闭合缺口与是否命中目标，
  距离不达标时如实上报，不做假。
"""
import itertools
from typing import Dict, List, Optional

from .geo import GeoPoint, haversine
from .nav_metrics import analyze_route
from .planner import MapPlanner
from .scorer import score_route
from .types import LoopRoute, RouteSegment

# 闭环判定阈值：起终点折线首尾直线距离（米）。超过即视为「断了」，不采纳。
CLOSURE_TOL_M = 50.0


def _build(planner: MapPlanner, seq: List[GeoPoint],
           closure_tol_m: float = CLOSURE_TOL_M) -> Optional[LoopRoute]:
    """按给定有序点列逐段真实规划成闭环（末点回到首点）。

    返回的 LoopRoute 若未闭合，error 非空；调用方不得把它当作可用闭环。
    """
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
    closure = round(haversine(allpts[0], allpts[-1]), 2)
    err = None
    if closure > closure_tol_m:
        err = f"闭合缺口 {closure:.1f}m 超过 {closure_tol_m:.0f}m（拒绝切断闭环）"
    return LoopRoute(distance_m=total, duration_s=dur,
                     closure_m=closure,
                     start_snap_m=round(haversine(seq[0], allpts[0]), 2),
                     polyline=allpts, segments=segs, error=err)


def _removable_m(anchors: List[GeoPoint], base: LoopRoute, i: int) -> float:
    """估算去掉第 i 个锚点能省多少米（用于优先尝试最该裁的拐点）。"""
    n = len(anchors)
    if not (1 <= i < n):
        return -1.0
    prev = anchors[i - 1]
    nxt = anchors[(i + 1) % n]
    incoming = base.segments[i - 1].distance_m if i - 1 < len(base.segments) else 0.0
    outgoing = base.segments[i].distance_m if i < len(base.segments) else 0.0
    return incoming + outgoing - haversine(prev, nxt)


def build_anchor_loop(planner: MapPlanner,
                      anchors: List[GeoPoint],
                      target_m: int,
                      tol_m: float = 500.0,
                      max_drop_total: int = 3,
                      max_builds: int = 220,
                      closure_tol_m: float = CLOSURE_TOL_M) -> Dict:
    """锚点闭环 + 多拐点裁剪（裁剪后必须仍闭合到首锚点）。

    裁剪 = 去掉 1~max_drop_total 个内部锚点后，对剩余锚点**重新逐段真实规划**
    并闭合回首锚点；绝不对折线做截断，因此闭合性质由构造保证。首锚点
    （用户起点）永不丢。最多尝试 max_builds 个组合，避免无界调用。

    返回 {ok, loop, anchors_used, best, candidates, error}
    - candidates 只含**闭合**候选；drop=-1 表示未裁剪；
    - 若所有候选都闭合失败，loop=None，error 说明原因。
    """
    if len(anchors) < 4:
        return {"ok": False, "error": "锚点少于 4 个，无法构成闭环",
                "loop": None, "anchors_used": 0, "best": None, "candidates": []}

    seq = list(anchors) + [anchors[0]]
    base = _build(planner, seq, closure_tol_m)

    def evaluate(loop: LoopRoute, drops: List[int]) -> Dict:
        steps = [s for seg in loop.segments for s in seg.steps]
        m = analyze_route(steps, loop.polyline, target_m,
                          segments=loop.segments)
        score = score_route(target_m, loop, m)
        return {"drop": drops[0] if drops else -1,
                "drops": list(drops),
                "distance": round(loop.distance_m, 1),
                "err": round(loop.distance_m - target_m, 1),
                "closure_m": loop.closure_m, "closure_ok": loop.error is None,
                "turns": m.get("turns"), "density": m.get("turn_density"),
                "rep": m.get("repetition_ratio"),
                "walk_bad": m.get("walk_bad_ratio"),
                "score": score.total, "metrics": m, "loop": loop}

    cands: List[Dict] = []
    base_error: Optional[str] = None
    if base is not None and base.error is None:
        cands.append(evaluate(base, []))
    elif base is not None:
        base_error = base.error

    # 裁剪：只尝试内部锚点（首锚点 = 起点，永不丢）。支持同时去掉 2~3 个
    # 拐点，因为实测 2.5km 目标单去一个拐点只能到 2777m；三拐点可到 2593m
    # 且仍闭合（闭合缺口 0.59m）。所有组合都重新真实规划，不切折线。
    if base is not None and base.error is None:
        n = len(anchors)
        k_max = max(1, min(max_drop_total, n - 3))
        combos = []
        for k in range(1, k_max + 1):
            for drops in itertools.combinations(range(1, n), k):
                saving = sum(_removable_m(anchors, base, i) for i in drops)
                combos.append((saving, drops))
        # 先试「省距最多」的组合，预算内尽量覆盖；小规模锚点会全部覆盖。
        combos.sort(key=lambda x: x[0], reverse=True)
        for _, drops in combos[:max(1, max_builds)]:
            keep = [p for i, p in enumerate(anchors) if i not in drops]
            if len(keep) < 3:
                continue
            loop = _build(planner, keep + [keep[0]], closure_tol_m)
            if loop is not None and loop.error is None:
                cands.append(evaluate(loop, list(drops)))

    if not cands:
        return {"ok": False,
                "error": base_error or "锚点闭环未闭合或存在不可达路段（已拒绝切断闭环）",
                "loop": None, "anchors_used": 0, "best": None, "candidates": []}

    within = [c for c in cands if abs(c["err"]) <= tol_m]
    pool = within or cands
    if within:
        # 达标优先：评分高者胜；同分取误差小、裁剪少者。
        best = max(pool, key=lambda c: (c["score"], -abs(c["err"]),
                                        -len(c["drops"])))
    else:
        best = min(pool, key=lambda c: abs(c["err"]))
    ok = abs(best["err"]) <= tol_m

    compact = []
    for c in cands:
        compact.append({k: v for k, v in c.items() if k not in ("loop", "metrics")})
    compact.sort(key=lambda c: (abs(c["err"]), -c["score"]))
    return {
        "ok": ok,
        "loop": best["loop"],
        "anchors_used": len(anchors) - len(best.get("drops") or []),
        "best": best,
        "candidates": compact,
        "error": None if ok else "锚点闭环距离仍超出容差（如实返回，不凑数）",
    }
