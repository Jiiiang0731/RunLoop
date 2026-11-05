#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""动态重规划（阶段 M-D，任务书 5.4/5.5/5.7）。

策略（任务书原文）：
    当前真实位置 → 重新规划接入路径 → 原规划路线前方的合适接回点
    → 原路线剩余部分 → 最终回到终点。

要点：
- 候选接回点**只从剩余路线**（along_m 之后）采样——结构上杜绝
  「接入已跑过的历史路段」（任务书 5.7#4）；
- 每个候选用高德真实步行规划计算连接段（真实道路，不画直线）；
- 评分 = 绕行净增距离 (connector - skipped) + 转弯惩罚，
  对应任务书 5.4#6 的「绕行距离、转弯数量、道路连贯性、接回后长度」；
- 目标距离诚实（5.5）：优先选总距离仍落在 target ±tol 的方案；
  没有达标方案时如实返回新预计总距离 + within_tolerance=false，
  绝不伪装成仍符合目标；
- API 预算硬上限（5.7#10）：候选评估次数 ≤ max_calls，超限即停止评估；
- 不修改原路线已完成部分与 GPS 轨迹（客户端职责，本模块只读输入）。

可离线单测：planner 依赖注入（MockPlanner / FakePlanner 均可）。
"""
import math
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, List, Optional

from .guard import looks_throttled
from .route_generator.geo import GeoPoint, haversine
from .route_generator.nav_text import build_nav_instructions
from .route_generator.planner import MapPlanner
from .route_generator.types import PlanStep

# 候选接回点最少间隔（米）——太近的接回点对「走错路口」没有意义
_MIN_REJOIN_AHEAD_M = 80.0
# 转弯惩罚（米/个）：一个多余转弯 ≈ 12m 绕行成本
_TURN_PENALTY_M = 12.0
# 非直行动作关键字（与 nav_metrics._is_turn_action 同源语义）
_TURN_ACTIONS = ("左转", "右转", "向左", "向右", "掉头", "斜向")


@dataclass
class RejoinCandidate:
    """一个候选接回点的评估记录。"""
    along_m: float                 # 在原路线上的累计里程
    point: GeoPoint
    ok: bool = False
    connector_m: Optional[float] = None
    duration_s: float = 0.0
    skipped_m: float = 0.0         # 接回点与当前进度之间被跳过的原路线长度
    extra_m: Optional[float] = None  # 净增距离 = connector - skipped
    turns: int = 0
    score: Optional[float] = None
    estimated_total_m: Optional[float] = None
    within_tolerance: Optional[bool] = None
    error: Optional[str] = None
    # 内部字段：切线方位（候选排序用）/ 选中后取用的规划结果
    tangent: Optional[float] = field(default=None, repr=False)
    plan: Any = field(default=None, repr=False)


@dataclass
class RerouteResult:
    ok: bool
    error_code: Optional[str] = None     # BAD_REQUEST / NO_REJOIN / AMAP_ERROR
    error: Optional[str] = None
    reroute_id: str = ""
    chosen: Optional[RejoinCandidate] = None
    connector_points: List[GeoPoint] = field(default_factory=list)
    connector_steps: List[dict] = field(default_factory=list)  # 序列化导航步骤
    connector_m: float = 0.0
    connector_duration_s: float = 0.0
    merged_remaining: List[GeoPoint] = field(default_factory=list)
    remaining_m: float = 0.0             # 连接段 + 原路线剩余
    estimated_total_m: float = 0.0       # completed + remaining（诚实口径）
    within_tolerance: bool = False
    tol_effective_m: float = 0.0         # 实际使用的容差（相对目标，阶段 N）
    candidates: List[RejoinCandidate] = field(default_factory=list)
    api_calls: int = 0
    elapsed_s: float = 0.0


def _cumulative(polyline: List[GeoPoint]) -> List[float]:
    cum = [0.0]
    for i in range(len(polyline) - 1):
        cum.append(cum[-1] + haversine(polyline[i], polyline[i + 1]))
    return cum


def _point_at(polyline: List[GeoPoint], cum: List[float], s: float) -> GeoPoint:
    """折线上里程 s 处的插值点。"""
    if s <= 0:
        return polyline[0]
    if s >= cum[-1]:
        return polyline[-1]
    # 二分找段
    lo, hi = 0, len(cum) - 1
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if cum[mid] <= s:
            lo = mid
        else:
            hi = mid
    seg = cum[lo + 1] - cum[lo]
    frac = 0.0 if seg <= 0 else (s - cum[lo]) / seg
    a, b = polyline[lo], polyline[lo + 1]
    return (a[0] + (b[0] - a[0]) * frac, a[1] + (b[1] - a[1]) * frac)


def _tangent_at(polyline: List[GeoPoint], cum: List[float], s: float) -> float:
    """折线上里程 s 处的切线方位角（度，正北顺时针）。"""
    ahead = _point_at(polyline, cum, min(s + 15.0, cum[-1]))
    back = _point_at(polyline, cum, max(s - 15.0, 0.0))
    if haversine(back, ahead) < 1.0:
        return 0.0
    dlng = math.radians(ahead[0] - back[0])
    lat1, lat2 = math.radians(back[1]), math.radians(ahead[1])
    y = math.sin(dlng) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlng)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def _ang_diff(a: float, b: float) -> float:
    d = abs(a - b) % 360.0
    return 360.0 - d if d > 180.0 else d


def _count_turns(steps: List[PlanStep]) -> int:
    n = 0
    for st in steps:
        act = (st.action or "") + (st.instruction or "")
        if any(k in act for k in _TURN_ACTIONS):
            n += 1
    return n


def pick_rejoin_candidates(polyline: List[GeoPoint],
                           cum: List[float],
                           along_m: float,
                           heading: Optional[float],
                           budget: int) -> List[RejoinCandidate]:
    """在剩余路线上采样候选接回点（任务书 5.4#3/#4）。

    - 起点 = along_m + max(80m, 剩余 8%)：太近的接回没有意义；
    - 终点候选恒包含（保住闭环回终点的语义）；
    - heading 给定时，切线方向与行进方向夹角 >110° 的候选排后
      （大概率是对向/返程段，绕开「错误接入」但不硬性排除）。
    """
    total = cum[-1]
    remaining = total - along_m
    budget = max(1, min(6, budget))
    cands: List[RejoinCandidate] = []
    if remaining <= _MIN_REJOIN_AHEAD_M + 20:
        # 快到终点：唯一候选 = 终点
        cands.append(RejoinCandidate(along_m=total, point=polyline[-1]))
        return cands

    first = along_m + max(_MIN_REJOIN_AHEAD_M, remaining * 0.08)
    if budget == 1:
        positions = [total]
    else:
        step = (total - first) / (budget - 1)
        positions = [first + step * i for i in range(budget)]
        positions[-1] = total  # 强制含终点

    seen = set()
    for s in positions:
        s = min(max(s, first), total)
        key = round(s / 25.0)  # 25m 内去重
        if key in seen:
            continue
        seen.add(key)
        c = RejoinCandidate(along_m=s, point=_point_at(polyline, cum, s))
        if heading is not None:
            c.tangent = _tangent_at(polyline, cum, s)
        cands.append(c)

    if heading is not None and len(cands) > 1:
        # 切线方向与行进方向夹角 >110° 的候选排后：大概率是对向/返程段，
        # 预算受限时优先评估「顺着跑的方向」的接回点（任务书 5.4#4）。
        cands.sort(key=lambda c: 1.0 if _ang_diff(c.tangent or 0.0, heading) > 110.0 else 0.0)
    return cands


def reroute(planner: MapPlanner,
            origin: GeoPoint,
            polyline: List[GeoPoint],
            along_m: float,
            target_m: float,
            completed_m: float,
            heading: Optional[float] = None,
            tol_m: float = 500.0,
            max_calls: int = 5) -> RerouteResult:
    """执行一次动态重规划。planner 注入（生产 = AmapWalkingPlanner）。"""
    t0 = time.time()
    rid = "rr-" + uuid.uuid4().hex[:10]

    # ---- 输入校验（5.7#1：跳点/脏数据直接拒绝，绝不用坏数据规划） ----
    if len(polyline) < 2:
        return RerouteResult(ok=False, error_code="BAD_REQUEST",
                             error="polyline 少于 2 点", reroute_id=rid)
    cum = _cumulative(polyline)
    total = cum[-1]
    if total < 50:
        return RerouteResult(ok=False, error_code="BAD_REQUEST",
                             error="原路线过短，无法重规划", reroute_id=rid)
    if not (0 <= along_m < total):
        return RerouteResult(ok=False, error_code="BAD_REQUEST",
                             error=f"along_m={along_m:.0f} 超出路线里程 [0,{total:.0f})",
                             reroute_id=rid)
    if completed_m < 0 or not (0 < target_m <= 100000):
        return RerouteResult(ok=False, error_code="BAD_REQUEST",
                             error="completed_m/target_m 非法", reroute_id=rid)

    cands = pick_rejoin_candidates(polyline, cum, along_m, heading,
                                   budget=max_calls)
    api_calls = 0
    evaluated: List[RejoinCandidate] = []
    # 阶段 N：重规划也按相对目标判达标（±500m 是上限，不是合格线）。
    # 1km→50m、2.5km→125m、5km→250m，长距离仍受 ±500m 约束。
    rel_tol = min(float(tol_m), max(30.0, 0.05 * float(target_m)))

    for c in cands:
        if api_calls >= max_calls:
            break
        api_calls += 1
        res = planner.plan_walking(origin, c.point)
        c.skipped_m = c.along_m - along_m
        if not res.ok:
            c.error = res.error or "规划失败"
            evaluated.append(c)
            continue
        c.ok = True
        c.connector_m = res.distance_m
        c.duration_s = res.duration_s
        c.extra_m = res.distance_m - c.skipped_m
        c.turns = _count_turns(res.steps)
        c.score = c.extra_m + _TURN_PENALTY_M * c.turns
        c.estimated_total_m = completed_m + res.distance_m + (total - c.along_m)
        c.within_tolerance = abs(c.estimated_total_m - target_m) <= rel_tol
        # 评分（阶段 N 修正）：以「保持目标里程」为第一目标，其次连接段短、
        # 转弯少。旧式 extra_m=connector-skipped 会奖励「跳过更多原路线」，
        # 实测把 1km 路线缩成 604m 还判达标——废弃。
        c.score = (abs(c.estimated_total_m - target_m)
                   + 0.5 * res.distance_m
                   + _TURN_PENALTY_M * c.turns)
        c.plan = res  # 暂存连接结果供选中后使用（候选 ≤6，内存可忽略）
        evaluated.append(c)

    oks = [c for c in evaluated if c.ok]
    if not oks:
        throttled = any(looks_throttled(c.error) for c in evaluated)
        return RerouteResult(
            ok=False,
            error_code="AMAP_ERROR" if throttled else "NO_REJOIN",
            error="高德接口限流/失败，请稍后重试" if throttled
                  else "所有候选接回点均无法步行到达",
            reroute_id=rid, candidates=evaluated,
            api_calls=api_calls, elapsed_s=time.time() - t0)

    # ---- 选择（5.5：目标距离诚实） ----
    within = [c for c in oks if c.within_tolerance]
    pool = within if within else oks
    chosen = min(pool, key=lambda c: (c.score if c.score is not None else 1e9))

    res = chosen.plan
    for c in evaluated:
        c.plan = None  # 序列化前释放，不进响应

    # ---- 合并：连接段 + 原路线剩余（接缝去重） ----
    rejoin_pts = [_point_at(polyline, cum, chosen.along_m)]
    tail_idx = 0
    for i in range(len(cum) - 1):
        if cum[i + 1] >= chosen.along_m:
            tail_idx = i + 1
            break
    merged = list(res.points)
    if merged and rejoin_pts and haversine(merged[-1], rejoin_pts[0]) < 30:
        merged = merged[:-1]  # 连接段终点即接回点，去重接缝
    merged.extend(rejoin_pts)
    merged.extend(polyline[tail_idx:])
    merged = _dedup(merged)

    remaining_m = (chosen.connector_m or 0.0) + (total - chosen.along_m)
    estimated_total = completed_m + remaining_m

    return RerouteResult(
        ok=True,
        reroute_id=rid,
        chosen=chosen,
        connector_points=list(res.points),
        connector_steps=_serialize_connector_steps(res.steps),
        connector_m=round(chosen.connector_m or 0.0, 1),
        connector_duration_s=round(res.duration_s, 1),
        merged_remaining=[[round(p[0], 6), round(p[1], 6)] for p in merged],
        remaining_m=round(remaining_m, 1),
        estimated_total_m=round(estimated_total, 1),
        within_tolerance=bool(chosen.within_tolerance),
        tol_effective_m=round(rel_tol, 1),
        candidates=evaluated,
        api_calls=api_calls,
        elapsed_s=time.time() - t0,
    )


def _serialize_connector_steps(steps: List[PlanStep]) -> List[dict]:
    """连接段真实 steps → 客户端 RouteStep 契约（与 /generate 同构）。"""
    out = []
    for item in build_nav_instructions(steps):
        out.append({
            "instruction": item["text"],
            "text": item["text"],
            "road": item["road"],
            "distance_m": item["distance_m"],
            "cumulative_m": item["cumulative_m"],
            "action": item["turn"],
            "turn": item["turn"],
            "orientation": "",
            "junction": item["junction"],
            "polyline": [],
        })
    return out


def _dedup(points: List[GeoPoint], min_gap_m: float = 1.0) -> List[GeoPoint]:
    out: List[GeoPoint] = []
    for p in points:
        if not out or haversine(out[-1], p) >= min_gap_m:
            out.append(p)
    if len(points) > 1 and out and out[-1] != points[-1]:
        out.append(points[-1])
    return out
