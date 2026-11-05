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
from .route_generator.nav_text import bearing, build_nav_instructions
from .route_generator.planner import MapPlanner
from .route_generator.types import PlanResult, PlanStep

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
    # 阶段 Q：前向约束诊断
    initial_angle_deg: Optional[float] = None
    forward_gain_m: Optional[float] = None
    backtrack_m: Optional[float] = None
    forward_ok: bool = True
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
    # 阶段 Q：前向重规划上下文
    strategy: str = "legacy"              # legacy / forward_rejoin / forward_loop
    request_id: str = ""
    actual_along_m: float = 0.0
    heading_used: Optional[float] = None
    heading_source: str = "none"
    heading_confidence: float = 0.0


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


def _normalize_heading(h: Optional[float]) -> Optional[float]:
    if h is None:
        return None
    try:
        v = float(h)
    except (TypeError, ValueError):
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v % 360.0


def _project_origin(polyline: List[GeoPoint], cum: List[float],
                    p: GeoPoint, hint: Optional[float] = None,
                    window_m: float = 500.0):
    """把当前 GPS 点投影到原路线，返回 (along_m, offset_m)。

    偏航时点可能离路线几十米；用 ±window 的局部窗口，避免去/返程串腿。
    """
    n = len(polyline)
    if n == 0:
        return 0.0, float("inf")
    if n == 1:
        return 0.0, haversine(p, polyline[0])
    if hint is None or math.isnan(hint):
        i0, i1 = 0, n - 2
    else:
        lo = max(0.0, float(hint) - window_m)
        hi = min(cum[-1], float(hint) + window_m)
        i0 = 0
        while i0 < n - 2 and cum[i0 + 1] < lo:
            i0 += 1
        i1 = i0
        while i1 < n - 2 and cum[i1] < hi:
            i1 += 1
    cos_lat = math.cos(math.radians(p[1]))
    px, py = p[0] * cos_lat, p[1]
    best_along, best_off = cum[i0], float("inf")
    for i in range(i0, i1 + 1):
        a, b = polyline[i], polyline[i + 1]
        ax, ay = a[0] * cos_lat, a[1]
        dx, dy = b[0] * cos_lat - ax, b[1] - ay
        len2 = dx * dx + dy * dy
        t = 0.0 if len2 <= 0 else ((px - ax) * dx + (py - ay) * dy) / len2
        t = max(0.0, min(1.0, t))
        proj = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        off = haversine(p, proj)
        if off < best_off:
            best_off = off
            best_along = cum[i] + (cum[i + 1] - cum[i]) * t
    return best_along, best_off


def _point_at_distance(points: List[GeoPoint], d: float) -> GeoPoint:
    if not points:
        return (0.0, 0.0)
    if len(points) == 1:
        return points[0]
    cum = _cumulative(points)
    return _point_at(points, cum, max(0.0, min(float(d), cum[-1])))


def _connector_metrics(points: List[GeoPoint], origin: GeoPoint,
                       heading: float, min_forward_gain_m: float,
                       max_backtrack_m: float,
                       max_initial_angle_deg: float):
    """真实连接段的前向性：首段方位、前 80m 前进增益、最大回退。"""
    if not points or len(points) < 2:
        return 180.0, 0.0, 999.0, False
    cum = _cumulative(points)
    k = 0
    while k < len(points) - 1 and cum[k] < 20.0:
        k += 1
    start_b = bearing(points[0], points[min(k, len(points) - 1)])
    initial = _ang_diff(start_b, heading)
    cos_lat = math.cos(math.radians(origin[1]))
    mlng = 111320.0 * cos_lat
    mlat = 110574.0
    u_e = math.sin(math.radians(heading))
    u_n = math.cos(math.radians(heading))
    min_proj = 0.0
    max_proj = 0.0
    for i, p in enumerate(points):
        if cum[i] > 100.0:
            break
        east = (p[0] - origin[0]) * mlng
        north = (p[1] - origin[1]) * mlat
        proj = east * u_e + north * u_n
        min_proj = min(min_proj, proj)
        max_proj = max(max_proj, proj)
    backtrack = max(0.0, -min_proj)
    forward_gain = max_proj
    ok = (initial <= max_initial_angle_deg
          and backtrack <= max_backtrack_m
          and forward_gain >= min_forward_gain_m)
    return initial, forward_gain, backtrack, ok


def _recent_points_heading(recent_points):
    """从最近可靠 GPS 点推导稳定移动方向（不依赖指南针）。

    输入项可以是 dict（lng/lat/accuracy/speed/timestamp_ms）或
    [lng, lat, accuracy, speed, timestamp_ms]。
    """
    if not recent_points:
        return None
    now_ms = time.time() * 1000.0
    pts = []
    for item in recent_points:
        try:
            if isinstance(item, dict):
                lng = float(item.get("lng"))
                lat = float(item.get("lat"))
                acc = float(item.get("accuracy_m", item.get("accuracy", 0)) or 0)
                spd = float(item.get("speed_mps", item.get("speed", 0)) or 0)
                ts = float(item.get("timestamp_ms", item.get("ts", 0)) or 0)
                brg = item.get("bearing")
            else:
                lng, lat = float(item[0]), float(item[1])
                acc = float(item[2] or 0) if len(item) > 2 else 0
                spd = float(item[3] or 0) if len(item) > 3 else 0
                ts = float(item[4] or 0) if len(item) > 4 else 0
                brg = item[5] if len(item) > 5 else None
        except (TypeError, ValueError, IndexError):
            continue
        if not (-180 <= lng <= 180 and -90 <= lat <= 90):
            continue
        if ts < 1e11:  # 秒 → 毫秒
            ts *= 1000.0
        if ts <= 0 or now_ms - ts > 30000:
            continue
        if acc > 50.0:
            continue
        pts.append((lng, lat, acc, spd, ts, brg))
    if not pts:
        return None
    pts.sort(key=lambda x: x[4])
    dedup = []
    for p in pts:
        if not dedup or haversine((dedup[-1][0], dedup[-1][1]), (p[0], p[1])) >= 2.0:
            dedup.append(p)
    pts = dedup
    if len(pts) >= 2:
        d = haversine((pts[0][0], pts[0][1]), (pts[-1][0], pts[-1][1]))
        dt = (pts[-1][4] - pts[0][4]) / 1000.0
        if d >= 8.0 and dt >= 2.0 and d / max(dt, 0.1) >= 0.6:
            h = bearing((pts[0][0], pts[0][1]), (pts[-1][0], pts[-1][1]))
            conf = min(0.9, 0.45 + 0.08 * min(len(pts), 5)
                       + (0.2 if d >= 20.0 else 0.0))
            return h, "recent_points", round(conf, 2), int(now_ms - pts[-1][4])
    # 单点 + 原生 bearing：只作低置信度兜底
    p = pts[-1]
    if p[5] is not None and p[3] >= 1.0:
        h = _normalize_heading(float(p[5]))
        if h is not None:
            return h, "gps_course", 0.55, int(now_ms - p[4])
    return None


def _resolve_heading(heading, heading_source, heading_confidence,
                     heading_age_ms, recent_points):
    """方向可信度仲裁：GPS/连续轨迹优先，指南针与原路线切线不作为主来源。"""
    h = _normalize_heading(heading)
    conf = float(heading_confidence or 0.0)
    src = (heading_source or ("gps" if h is not None else "none")).strip()
    age = heading_age_ms
    if h is not None:
        if not conf:
            # 旧客户端只发 heading：不直接拒绝，给中等置信度。
            conf = 0.6 if src in ("gps", "gps_course", "provided") else 0.35
        if src in ("route", "compass"):
            # 任务书明确：不得用原路线下一段方向/单纯指南针代替真实移动方向
            h = None
        elif src == "frozen" and age is not None and age > 30000:
            h = None
        if h is not None and conf >= 0.35:
            return h, src, min(0.95, conf), int(age or 0)
    rh = _recent_points_heading(recent_points)
    if rh is not None:
        return rh
    if h is not None and src == "frozen" and conf >= 0.35:
        return h, src, min(0.6, conf), int(age or 0)
    return None, "none", 0.0, int(age or 0)


def _offset_point(origin: GeoPoint, heading: float, dist_m: float) -> GeoPoint:
    lat = origin[1] + math.cos(math.radians(heading)) * dist_m / 110574.0
    lng = origin[0] + math.sin(math.radians(heading)) * dist_m / (
        111320.0 * math.cos(math.radians(origin[1])))
    return (lng, lat)


def pick_rejoin_candidates(polyline: List[GeoPoint],
                           cum: List[float],
                           along_m: float,
                           heading: Optional[float],
                           budget: int,
                           forward_only: bool = False,
                           actual_along_m: Optional[float] = None,
                           min_forward_gain_m: float = 10.0,
                           max_initial_angle_deg: float = 90.0
                           ) -> List[RejoinCandidate]:
    """在剩余路线上采样候选接回点（任务书 5.4#3/#4）。

    - 起点 = along_m + max(80m, 剩余 8%)：太近的接回没有意义；
    - 终点候选恒包含（保住闭环回终点的语义）；
    - forward_only=True（阶段 Q）：以真实当前投影 actual_along_m 为基准，
      结构上排除身后点；切线方向与 heading 夹角 > max_initial_angle_deg
      的候选直接剔除（不浪费 API 去规划一条回头路）；按方向贴合度排序。
    """
    total = cum[-1]
    base = (actual_along_m if (forward_only and actual_along_m is not None)
            else along_m)
    remaining = total - base
    budget = max(1, min(8 if forward_only else 6, budget))
    cands: List[RejoinCandidate] = []
    if remaining <= _MIN_REJOIN_AHEAD_M + 20:
        c = RejoinCandidate(along_m=total, point=polyline[-1])
        if heading is not None:
            c.tangent = _tangent_at(polyline, cum, total)
        if forward_only and heading is not None and \
                _ang_diff(c.tangent or 0.0, heading) > max_initial_angle_deg:
            return []
        return [c]

    first = base + max(_MIN_REJOIN_AHEAD_M, remaining * 0.08)
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
        if forward_only:
            # 结构上不允许接回身后/刚跑过的部分
            if c.along_m < base + min_forward_gain_m - 1e-6:
                continue
            # 切线明显反向的候选不评估：它会把用户带回刚刚错过的路口
            if heading is not None and \
                    _ang_diff(c.tangent or 0.0, heading) > max_initial_angle_deg:
                continue
        cands.append(c)

    if heading is not None and len(cands) > 1:
        if forward_only:
            # 方向贴合度优先：越顺着当前行进方向的接回点越先评估
            cands.sort(key=lambda c: _ang_diff(c.tangent or 0.0, heading))
        else:
            # 旧行为：切线方向与行进方向夹角 >110° 的候选排后
            cands.sort(key=lambda c: 1.0 if _ang_diff(c.tangent or 0.0, heading) > 110.0 else 0.0)
    return cands


def _forward_alternative(planner: MapPlanner, origin: GeoPoint,
                         heading: float, route_end: GeoPoint,
                         total: float, actual_along: float,
                         target_m: float, completed_m: float,
                         rel_tol: float, min_forward_gain_m: float,
                         max_backtrack_m: float, max_initial_angle_deg: float,
                         max_calls: int, api_calls: int,
                         heading_source: str, heading_confidence: float,
                         request_id: str, rid: str, t0: float):
    """前向替代路线：当前位置 → 沿当前方向前进 → 回到原定终点。

    只在无法接回原路线剩余部分时使用；每次尝试 2 个真实步行请求，
    预算用完即停。仍然坚持首段方向/回退校验，绝不靠掉头凑路线。
    """
    remaining_target = max(0.0, target_m - completed_m)
    fractions = (0.25, 0.5, 0.75)
    # 短探针优先：先试“继续向前 300/600m 再自然绕回”，避免一上来就
    # 选择过远的点（真实 5km 测试中 25% 剩余≈650m 的首段已开始回退）。
    distances = sorted({300, 600,
                        *[int(max(150.0, min(1500.0, remaining_target * f)))
                          for f in fractions]})
    max_points = max(0, (max_calls - api_calls) // 2)
    if max_points <= 0:
        return None
    best = None
    evaluated: List[RejoinCandidate] = []
    for d in distances[:max_points]:
        ahead = _offset_point(origin, heading, d)
        r1 = planner.plan_walking(origin, ahead)
        api_calls += 1
        if not r1.ok or not r1.points:
            continue
        a1, g1, b1, ok1 = _connector_metrics(
            r1.points, origin, heading, min_forward_gain_m,
            max_backtrack_m, max_initial_angle_deg)
        if not ok1:
            evaluated.append(RejoinCandidate(
                along_m=total, point=route_end, ok=False,
                initial_angle_deg=round(a1, 1),
                forward_gain_m=round(g1, 1), backtrack_m=round(b1, 1),
                forward_ok=False, error="首段方向不向前",
                estimated_total_m=completed_m + r1.distance_m + (total - actual_along)))
            continue
        if api_calls >= max_calls:
            break
        r2 = planner.plan_walking(ahead, route_end)
        api_calls += 1
        if not r2.ok or not r2.points:
            continue
        # 连接点处不能是明显掉头
        if len(r1.points) >= 2 and len(r2.points) >= 2:
            b_in = bearing(r1.points[-2], r1.points[-1])
            b_out = bearing(r2.points[0], r2.points[1])
            if _ang_diff(b_in, b_out) > 120.0:
                continue
        merged = _dedup(list(r1.points) + list(r2.points))
        remaining = r1.distance_m + r2.distance_m
        estimated = completed_m + remaining
        within = abs(estimated - target_m) <= rel_tol
        turns = _count_turns(r1.steps) + _count_turns(r2.steps)
        score = (abs(estimated - target_m) + 0.5 * remaining
                 + _TURN_PENALTY_M * turns + 2.0 * max(0.0, a1 - 30.0)
                 + 4.0 * b1)
        cand = RejoinCandidate(
            along_m=total, point=route_end, ok=True,
            connector_m=round(remaining, 1), duration_s=r1.duration_s + r2.duration_s,
            skipped_m=round(total - actual_along, 1),
            extra_m=round(remaining - (total - actual_along), 1),
            turns=turns, score=round(score, 1),
            estimated_total_m=round(estimated, 1),
            within_tolerance=within,
            initial_angle_deg=round(a1, 1),
            forward_gain_m=round(g1, 1), backtrack_m=round(b1, 1),
            forward_ok=True, plan=(r1, r2),
        )
        evaluated.append(cand)
        if best is None:
            best = cand
        else:
            best_within = bool(best.within_tolerance)
            if within and not best_within:
                best = cand
            elif within == best_within and (cand.score or 1e9) < (best.score or 1e9):
                best = cand
    if best is None:
        return None
    r1, r2 = best.plan
    merged = _dedup(list(r1.points) + list(r2.points))
    steps = list(r1.steps) + list(r2.steps)
    remaining = float(best.connector_m or 0.0)
    estimated = completed_m + remaining
    return RerouteResult(
        ok=True,
        reroute_id=rid,
        strategy="forward_loop",
        request_id=request_id,
        chosen=best,
        actual_along_m=round(actual_along, 1),
        heading_used=round(heading, 1),
        heading_source=heading_source,
        heading_confidence=round(heading_confidence, 2),
        connector_points=merged,
        connector_steps=_serialize_connector_steps(steps, mark_end=True),
        connector_m=round(remaining, 1),
        connector_duration_s=round(best.duration_s, 1),
        merged_remaining=_dedup(merged),
        remaining_m=round(remaining, 1),
        estimated_total_m=round(estimated, 1),
        within_tolerance=bool(best.within_tolerance),
        tol_effective_m=round(rel_tol, 1),
        candidates=evaluated,
        api_calls=api_calls,
        elapsed_s=time.time() - t0,
    )


def _forward_reroute(planner: MapPlanner, origin: GeoPoint,
                     polyline: List[GeoPoint], cum: List[float],
                     total: float, along_m: float, target_m: float,
                     completed_m: float, heading: Optional[float],
                     heading_source: Optional[str],
                     heading_confidence: Optional[float],
                     heading_age_ms: Optional[int],
                     recent_points, route_end: Optional[GeoPoint],
                     request_id: Optional[str], sent_at_ms: Optional[float],
                     tol_m: float, max_calls: int,
                     min_forward_gain_m: float,
                     max_backtrack_m: float,
                     max_initial_angle_deg: float,
                     rid: str, t0: float) -> RerouteResult:
    """前向重规划主路径（阶段 Q）。"""
    # ---- 请求新鲜度 ----
    if sent_at_ms is not None:
        try:
            v = float(sent_at_ms)
            if v < 1e11:
                v *= 1000.0
            if time.time() * 1000.0 - v > 30000.0:
                return RerouteResult(ok=False, error_code="STALE_REQUEST",
                                     error="重规划请求已过期，请重试",
                                     reroute_id=rid, request_id=request_id or "")
        except (TypeError, ValueError):
            pass

    actual_along, offset = _project_origin(polyline, cum, origin,
                                           hint=along_m, window_m=500.0)
    actual_along = max(0.0, min(total, actual_along))
    if abs(actual_along - along_m) > 300.0 and not recent_points:
        return RerouteResult(
            ok=False, error_code="STALE_REQUEST",
            error="当前位置与原路线进度差异过大，请重试",
            reroute_id=rid, request_id=request_id or "",
            actual_along_m=round(actual_along, 1))

    hd, hsrc, hconf, hage = _resolve_heading(
        heading, heading_source, heading_confidence, heading_age_ms,
        recent_points)
    if hd is None or hconf < 0.35:
        return RerouteResult(
            ok=False, error_code="HEADING_UNRELIABLE",
            error="无法可靠判断当前前进方向，请继续沿道路跑几秒后重试",
            reroute_id=rid, request_id=request_id or "",
            actual_along_m=round(actual_along, 1),
            heading_source=hsrc, heading_confidence=round(hconf, 2))

    remaining_target = max(0.0, target_m - completed_m)
    if remaining_target < 80.0:
        return RerouteResult(
            ok=False, error_code="REMAINING_DISTANCE_INFEASIBLE",
            error="剩余目标距离过短，无法生成合理的前向路线",
            reroute_id=rid, request_id=request_id or "",
            actual_along_m=round(actual_along, 1),
            heading_used=round(hd, 1), heading_source=hsrc,
            heading_confidence=round(hconf, 2))

    rel_tol = min(float(tol_m), max(30.0, 0.05 * float(target_m)))
    end_point = route_end or polyline[-1]
    # 预留 2 次调用给“前向替代路线”兜底，避免候选把预算耗尽后无法回退。
    cand_budget = max_calls if max_calls < 3 else max(1, max_calls - 2)
    cands = pick_rejoin_candidates(
        polyline, cum, actual_along, hd, budget=cand_budget,
        forward_only=True, actual_along_m=actual_along,
        min_forward_gain_m=min_forward_gain_m,
        max_initial_angle_deg=max_initial_angle_deg)
    if not cands:
        fb = _forward_alternative(
            planner, origin, hd, end_point, total, actual_along,
            target_m, completed_m, rel_tol, min_forward_gain_m,
            max_backtrack_m, max_initial_angle_deg, max_calls, 0,
            hsrc, hconf, request_id or "", rid, t0)
        if fb is not None:
            return fb
        return RerouteResult(
            ok=False, error_code="NO_FORWARD_REJOIN",
            error="前方没有合适的原路线接回点，且无法生成向前延伸的替代路线",
            reroute_id=rid, request_id=request_id or "",
            actual_along_m=round(actual_along, 1),
            heading_used=round(hd, 1), heading_source=hsrc,
            heading_confidence=round(hconf, 2))

    api_calls = 0
    evaluated: List[RejoinCandidate] = []
    for c in cands:
        if api_calls >= max_calls:
            break
        api_calls += 1
        res = planner.plan_walking(origin, c.point)
        c.skipped_m = max(0.0, c.along_m - actual_along)
        if not res.ok:
            c.error = res.error or "规划失败"
            evaluated.append(c)
            continue
        c.ok = True
        c.connector_m = res.distance_m
        c.duration_s = res.duration_s
        a, g, b, fwd = _connector_metrics(
            res.points, origin, hd, min_forward_gain_m,
            max_backtrack_m, max_initial_angle_deg)
        c.initial_angle_deg = round(a, 1)
        c.forward_gain_m = round(g, 1)
        c.backtrack_m = round(b, 1)
        c.forward_ok = bool(fwd)
        c.turns = _count_turns(res.steps)
        c.estimated_total_m = completed_m + res.distance_m + (total - c.along_m)
        c.within_tolerance = abs(c.estimated_total_m - target_m) <= rel_tol
        c.extra_m = res.distance_m - c.skipped_m
        c.score = (abs(c.estimated_total_m - target_m)
                   + 0.5 * res.distance_m
                   + _TURN_PENALTY_M * c.turns
                   + 2.0 * max(0.0, a - 30.0)
                   + 4.0 * b
                   + 8.0 * max(0.0, min_forward_gain_m - g))
        c.plan = res
        evaluated.append(c)

    forward_oks = [c for c in evaluated if c.ok and c.forward_ok]
    if not forward_oks:
        if api_calls < max_calls:
            fb = _forward_alternative(
                planner, origin, hd, end_point, total, actual_along,
                target_m, completed_m, rel_tol, min_forward_gain_m,
                max_backtrack_m, max_initial_angle_deg, max_calls,
                api_calls, hsrc, hconf, request_id or "", rid, t0)
            if fb is not None:
                return fb
        if any(c.ok and not c.forward_ok for c in evaluated):
            code, msg = ("NO_FORWARD_REJOIN",
                         "前方接回点都需要先掉头/回退，已拒绝生成反向路线")
        elif any(looks_throttled(c.error or "") for c in evaluated):
            code, msg = "AMAP_ERROR", "高德接口限流/失败，请稍后重试"
        elif not evaluated:
            code, msg = "NO_FORWARD_REJOIN", "前方没有可用的接回点"
        else:
            code, msg = "NO_FORWARD_ROUTE", "无法生成合理的前向路线"
        return RerouteResult(
            ok=False, error_code=code, error=msg,
            reroute_id=rid, request_id=request_id or "",
            actual_along_m=round(actual_along, 1),
            heading_used=round(hd, 1), heading_source=hsrc,
            heading_confidence=round(hconf, 2),
            candidates=evaluated, api_calls=api_calls,
            elapsed_s=time.time() - t0)

    within = [c for c in forward_oks if c.within_tolerance]
    pool = within or forward_oks
    chosen = min(pool, key=lambda c: (c.score if c.score is not None else 1e9))
    res = chosen.plan
    for c in evaluated:
        c.plan = None

    # ---- 合并与结构校验 ----
    rejoin_pt = _point_at(polyline, cum, chosen.along_m)
    tail_idx = len(polyline) - 1
    for i in range(len(cum) - 1):
        if cum[i + 1] >= chosen.along_m:
            tail_idx = i + 1
            break
    merged = list(res.points)
    if merged and haversine(merged[-1], rejoin_pt) < 30.0:
        merged = merged[:-1]
    merged.append(rejoin_pt)
    merged.extend(polyline[tail_idx:])
    merged = _dedup(merged)
    if (len(merged) < 2
            or haversine(merged[0], origin) > 50.0
            or haversine(merged[-1], end_point) > 50.0):
        return RerouteResult(
            ok=False, error_code="ROUTE_ASSEMBLY_ERROR",
            error="新旧路线连接失败，请重试",
            reroute_id=rid, request_id=request_id or "",
            actual_along_m=round(actual_along, 1),
            heading_used=round(hd, 1), heading_source=hsrc,
            heading_confidence=round(hconf, 2),
            candidates=evaluated, api_calls=api_calls,
            elapsed_s=time.time() - t0)

    remaining_m = (chosen.connector_m or 0.0) + (total - chosen.along_m)
    estimated_total = completed_m + remaining_m
    return RerouteResult(
        ok=True,
        reroute_id=rid,
        strategy="forward_rejoin",
        request_id=request_id or "",
        chosen=chosen,
        actual_along_m=round(actual_along, 1),
        heading_used=round(hd, 1),
        heading_source=hsrc,
        heading_confidence=round(hconf, 2),
        connector_points=list(res.points),
        connector_steps=_serialize_connector_steps(res.steps),
        connector_m=round(chosen.connector_m or 0.0, 1),
        connector_duration_s=round(res.duration_s, 1),
        merged_remaining=[[round(p[0], 6), round(p[1], 6)] for p in merged],
        remaining_m=round(remaining_m, 1),
        estimated_total_m=round(estimated_total, 1),
        within_tolerance=bool(abs(estimated_total - target_m) <= rel_tol),
        tol_effective_m=round(rel_tol, 1),
        candidates=evaluated,
        api_calls=api_calls,
        elapsed_s=time.time() - t0,
    )


def reroute(planner: MapPlanner,
            origin: GeoPoint,
            polyline: List[GeoPoint],
            along_m: float,
            target_m: float,
            completed_m: float,
            heading: Optional[float] = None,
            tol_m: float = 500.0,
            max_calls: int = 5,
            forward_only: bool = False,
            heading_source: Optional[str] = None,
            heading_confidence: Optional[float] = None,
            heading_age_ms: Optional[int] = None,
            recent_points=None,
            route_end: Optional[GeoPoint] = None,
            request_id: Optional[str] = None,
            sent_at_ms: Optional[float] = None,
            min_forward_gain_m: float = 10.0,
            max_backtrack_m: float = 25.0,
            max_initial_angle_deg: float = 90.0) -> RerouteResult:
    """执行一次动态重规划。planner 注入（生产 = AmapWalkingPlanner）。

    forward_only=True 时走阶段 Q 的前向策略；默认 False 完全保留旧行为。
    """
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

    if forward_only:
        res = _forward_reroute(
            planner, origin, polyline, cum, total, along_m, target_m,
            completed_m, heading, heading_source, heading_confidence,
            heading_age_ms, recent_points, route_end, request_id, sent_at_ms,
            tol_m, max_calls, min_forward_gain_m, max_backtrack_m,
            max_initial_angle_deg, rid, t0)
        if not res.ok and res.strategy == "legacy":
            res.strategy = "forward"
        return res

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


def _serialize_connector_steps(steps: List[PlanStep],
                               mark_end: bool = False) -> List[dict]:
    """连接段真实 steps → 客户端 RouteStep 契约（与 /generate 同构）。

    连接段的最后一步通常只是“接回点”，不是整条路线的终点。旧实现无条件
    把它标成 end，客户端会提前播“已到达路线终点”。默认改为 straight；
    只有前向替代路线（真正回到原终点）才 mark_end=True。
    """
    nav = build_nav_instructions(steps)
    out = []
    for idx, item in enumerate(nav):
        action = item["turn"]
        txt = item["text"]
        if idx == len(nav) - 1 and action == "end" and not mark_end:
            action = "straight"
            if "到达起点" in txt:
                txt = txt.split("，到达起点")[0] + "，到达接回点"
            elif "到达起点" not in txt:
                txt = txt.rstrip("。") + "，到达接回点"
        out.append({
            "instruction": txt,
            "text": txt,
            "road": item["road"],
            "distance_m": item["distance_m"],
            "cumulative_m": item["cumulative_m"],
            "action": action,
            "turn": action,
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
