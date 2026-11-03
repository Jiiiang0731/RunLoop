#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""无效绕行（spur）识别与真实步行路径替换（阶段 K，用户规范第三部分）。

问题模式：路线在主路附近拐入短小支路，绕一个小弯又接回主路；或在局部形成
无位移的折返。这类绕行多由控制点分布或步行路网的 OD 规划造成，对闭环没有
实际贡献，却增加转弯与距离。

识别（几何法，与采样密度无关，用户 2.1 同款网格思路）：
- 对闭环折线做 25m 网格哈希；
- 空间距离 < match_m 而沿线弧长在 (min_span_m, max_span_m) 内的点对 (i, j)，
  其间的子路径即「疑似绕行区间」——去返两腿在空间上并拢、弧长却绕远；
- 候选区间还须通过「双向并拢度」结构校验（_fold_ratio ≥ MIN_FOLD_RATIO）：
  真绕行的去/返两腿是沿途互相并拢的同一条路；仅单点巧合接近（V 形交叉、
  环线经过起点附近）不构成重复路段，绝不能被当作绕行剪掉；
- max_span_m 同时保护两类合法几何：
  * 环线闭合区（首尾点空间重合、弧长≈全程）；
  * 大环路（>1.2km 的整块绕行通常是骨架有意为之，如绕公园一圈）。

替换（真实道路，绝不直线连接，用户 3.2）：
- 区间外扩对齐到导航 step 边界（保持 steps 与折线一致，导航文本可重建）；
- 调用高德步行规划重连进出口两点；
- 采用条件：明显更短（省 ≥ min_saving_m）、几何转弯数不增加、
  整线重复率不上升（防止把绕行换成另一条重复路）；
- 拼接后重算闭环距离/时长/闭合误差；是否仍达标由调用方（calibrator）
  复检 ±tol，并负责必要时重新校准（用户 3.3）。

安全边界：
- 只处理真实规划出的道路；替换路径同样来自步行 API，可通行性一致；
- 每次替换消耗 1 次 API 调用，max_fixes 限制总成本；
- 不修改起终点、不跨越环线闭合点。
"""
import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from .geo import GeoPoint, haversine
from .nav_text import bearing
from .planner import MapPlanner
from .scorer import repetition_ratio
from .types import LoopRoute, PlanStep, RouteSegment

# ---- 可调参数（集中定义，报告与测试引用同名常量） ----
CELL_M = 25.0            # 网格边长
MATCH_M = 25.0           # 空间并拢判定（去/返两腿中心线距离）
MIN_SPAN_M = 150.0       # 绕行子路径最短弧长（短于此多为正常路口几何）
MAX_SPAN_M = 1200.0      # 绕行子路径最长弧长（保护大环路/闭合区）
MIN_FOLD_RATIO = 0.5     # 区间内「双向并拢」边占比下限（真折返≈1，V形巧合≈0）
MIN_SAVING_M = 80.0      # 替换至少省下的米数，否则不值得动
MIN_TURN_DEG = 45.0      # 几何转弯判定角
MAX_FIXES = 3            # 单条路线最多替换次数（API 成本控制）


@dataclass
class SpurFix:
    """一次绕行替换的记录（审计/报告用）。"""
    span_m: float          # 原子路径弧长
    repl_m: float          # 替换路径长度
    saved_m: float         # 节省
    at: GeoPoint           # 入口位置（脱敏日志用）
    old_turns: int
    new_turns: int


@dataclass
class SpurFixResult:
    loop: LoopRoute
    calls: int
    fixes: List[SpurFix] = field(default_factory=list)
    attempts: List[dict] = field(default_factory=list)  # 被拒绝的候选（诊断）


def _cum_arc(polyline: List[GeoPoint]) -> List[float]:
    arc = [0.0]
    for i in range(1, len(polyline)):
        arc.append(arc[-1] + haversine(polyline[i - 1], polyline[i]))
    return arc


def _dedup(points: List[GeoPoint], min_gap_m: float = 1.0) -> List[GeoPoint]:
    """去掉连续重复/近重复点，防止零长度替换产生点堆积（<1m 漂移无导航意义）。"""
    if len(points) < 2:
        return list(points)
    out = [points[0]]
    for p in points[1:]:
        if haversine(out[-1], p) >= min_gap_m:
            out.append(p)
    return out


def _count_geo_turns(pts: List[GeoPoint], min_deg: float = MIN_TURN_DEG) -> int:
    """折线几何转弯数（相邻边方向变化 ≥ min_deg 记一次），用于替换前后对比。"""
    if len(pts) < 3:
        return 0
    turns = 0
    prev_b: Optional[float] = None
    for i in range(1, len(pts)):
        if pts[i] == pts[i - 1]:
            continue
        b = bearing(pts[i - 1], pts[i])
        if prev_b is not None:
            d = abs((b - prev_b + 540) % 360 - 180)
            if d >= min_deg:
                turns += 1
        prev_b = b
    return turns


def _fold_ratio(xy: List[Tuple[float, float]], arc: List[float],
                i: int, j: int, match_m: float,
                min_along_gap: float = 30.0) -> float:
    """区间 [i..j] 的双向并拢度：与「区间内弧长相距 > min_along_gap 的其他边」
    空间并拢（< 匹配半径）的边占比。

    结构判据（用户规范 2.1/3.1：真正的重复是「同一条路两个方向」）：
    - 真折返绕行：去/返两腿沿途互相并拢 → 比值接近 1.0；
    - 两段路仅在一点附近偶然接近（V 形巧合、环线经过起点附近）→ 接近 0，
      单点接近不构成「重复路段」，不得被当作绕行剪掉。
    匹配半径对稀疏采样自适应（不小于最长边的 0.75，上限 60m），
    防止去/返两腿采样错位导致漏配。
    """
    m = j - i
    if m < 4:
        return 0.0
    max_edge = 0.0
    mids: List[Tuple[float, float]] = []
    for k in range(i, j):
        dx = xy[k + 1][0] - xy[k][0]
        dy = xy[k + 1][1] - xy[k][1]
        max_edge = max(max_edge, math.hypot(dx, dy))
        mids.append(((xy[k][0] + xy[k + 1][0]) / 2.0,
                     (xy[k][1] + xy[k + 1][1]) / 2.0))
    r = min(60.0, max(match_m, max_edge * 0.75))
    # 弧长间隔下限须超过局部采样尺度（1.25×最长边），否则相邻边会互配为假折叠
    gap = max(min_along_gap, 1.25 * max_edge)
    g: Dict[Tuple[int, int], List[int]] = {}
    for k, (mx, my) in enumerate(mids):
        g.setdefault((int(mx // CELL_M), int(my // CELL_M)), []).append(k + i)
    hit = 0
    for k in range(i, j):
        mx, my = mids[k - i]
        gx, gy = int(mx // CELL_M), int(my // CELL_M)
        found = False
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for l in g.get((gx + dx, gy + dy), ()):
                    if abs(arc[l] - arc[k]) <= gap:
                        continue
                    if math.hypot(mids[l - i][0] - mx, mids[l - i][1] - my) <= r:
                        found = True
                        break
                if found:
                    break
            if found:
                break
        if found:
            hit += 1
    return hit / m


def find_spur_intervals(
    polyline: List[GeoPoint],
    match_m: float = MATCH_M,
    min_span_m: float = MIN_SPAN_M,
    max_span_m: float = MAX_SPAN_M,
    max_intervals: int = 8,
) -> List[Tuple[int, int]]:
    """找出疑似无效绕行的折线下标区间 [(i, j), ...]（i<j，含端点）。

    算法：网格哈希所有点 → 邻近格内两两配对 → 弧长窗口过滤 →
    按弧长降序贪心选取互不重叠的区间（大区间吞并小区间）。
    """
    n = len(polyline)
    if n < 16:
        return []
    arc = _cum_arc(polyline)
    total = arc[-1]
    if total <= 0:
        return []
    max_span = min(max_span_m, 0.35 * total)
    if max_span <= min_span_m:
        return []

    lat0 = sum(p[1] for p in polyline) / n
    mlng = 111320.0 * math.cos(math.radians(lat0))
    mlat = 110574.0
    x0 = sum(p[0] for p in polyline) / n * mlng
    y0 = lat0 * mlat

    grid: Dict[Tuple[int, int], List[int]] = {}
    xy: List[Tuple[float, float]] = []
    for i, p in enumerate(polyline):
        x = p[0] * mlng - x0
        y = p[1] * mlat - y0
        xy.append((x, y))
        grid.setdefault((int(x // CELL_M), int(y // CELL_M)), []).append(i)

    # 候选配对：空间近、弧长远
    cands: List[Tuple[int, int, float]] = []  # (i, j, span)
    seen: set = set()
    for i, (x, y) in enumerate(xy):
        gx, gy = int(x // CELL_M), int(y // CELL_M)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((gx + dx, gy + dy), ()):
                    if j <= i:
                        continue
                    span = arc[j] - arc[i]
                    if span <= min_span_m or span >= max_span:
                        continue
                    if math.hypot(xy[j][0] - x, xy[j][1] - y) > match_m:
                        continue
                    key = (i, j)
                    if key in seen:
                        continue
                    seen.add(key)
                    cands.append((i, j, span))
    if not cands:
        return []

    # 大区间优先，贪心去重叠（嵌套的绕行取最外层一次替换掉）；
    # 每个候选区间须通过双向并拢度结构校验，排除单点巧合接近。
    cands.sort(key=lambda t: -t[2])
    chosen: List[Tuple[int, int]] = []
    taken = [False] * n
    for i, j, _ in cands:
        if any(taken[i:j + 1]):
            continue
        if _fold_ratio(xy, arc, i, j, match_m) < MIN_FOLD_RATIO:
            continue
        for k in range(i, j + 1):
            taken[k] = True
        chosen.append((i, j))
        if len(chosen) >= max_intervals:
            break
    chosen.sort()
    return chosen


def _build_index_map(loop: LoopRoute) -> Optional[List[Tuple[int, int]]]:
    """折线下标 → (segment_idx, step_idx) 映射；结构不符时返回 None（放弃修复）。

    build_loop 拼接规则：首段全量 extend，其后各段跳过第 1 个点（共享端点去重）；
    段内点序 = 各 step.polyline 顺序拼接（planner._parse_polyline_from_steps）。
    """
    mapping: List[Tuple[int, int]] = []
    for si, seg in enumerate(loop.segments):
        step_of_point: List[Tuple[int, int]] = []
        for ti, st in enumerate(seg.steps):
            step_of_point.extend([(si, ti)] * len(st.polyline))
        if not step_of_point:
            # 跨段绕行替换后可能留下空段（0 steps ↔ 0 折线点，拼接仍一致），
            # 跳过而不是中止；真正的结构损坏由末尾长度校验兜底。
            continue
        # 与 build_loop 的 r.points 对应：段点列 = 所有 step 折线拼接
        start = 1 if si > 0 else 0
        if start >= len(step_of_point):
            return None
        mapping.extend(step_of_point[start:])
    if len(mapping) != len(loop.polyline):
        return None
    return mapping


def _step_bounds(loop: LoopRoute, mapping: List[Tuple[int, int]],
                 seg: int, step: int) -> Tuple[int, int]:
    """某 step 覆盖的折线下标闭区间 [lo, hi]。"""
    lo = hi = -1
    for idx, (s, t) in enumerate(mapping):
        if s == seg and t == step:
            if lo < 0:
                lo = idx
            hi = idx
    return lo, hi


def _try_fix_one(loop: LoopRoute, mapping: List[Tuple[int, int]],
                 interval: Tuple[int, int], planner: MapPlanner,
                 attempts: List[dict],
                 target_m: Optional[float] = None,
                 tol_m: float = 500.0) -> Tuple[Optional[LoopRoute], int, Optional[SpurFix]]:
    """对单个区间做 step 边界对齐 → 真实步行重连 → 校验 → 拼接。"""
    i, j = interval
    n = len(loop.polyline)
    seg_a, step_a = mapping[i]
    seg_b, step_b = mapping[j]
    a_lo, a_hi = _step_bounds(loop, mapping, seg_a, step_a)
    b_lo, b_hi = _step_bounds(loop, mapping, seg_b, step_b)

    # 就近对齐 step 边界（保持 steps 与折线一致，又不过度扩大替换范围）：
    # 入口点落在所在 step 后半 → 收紧到下一 step 起点；否则外扩到本 step 起点。
    # 出口点落在所在 step 前半 → 收紧到上一 step 终点；否则外扩到本 step 终点。
    if a_hi - i < i - a_lo and a_hi + 1 <= j:
        lo = a_hi + 1
    else:
        lo = a_lo
    if j - b_lo < b_hi - j and b_lo - 1 >= lo:
        hi = b_lo - 1
    else:
        hi = b_hi
    if not (0 <= lo < hi <= n - 1):
        attempts.append({"interval": [i, j], "reject": "snap_bounds"})
        return None, 0, None
    seg_a, step_a = mapping[lo]
    seg_b, step_b = mapping[hi]

    p_start = loop.polyline[lo]
    p_end = loop.polyline[hi]
    old_slice = loop.polyline[lo:hi + 1]
    old_len = sum(haversine(old_slice[k - 1], old_slice[k]) for k in range(1, len(old_slice)))
    # 真实 AMap step 可长达 1~2km：外扩对齐后区间过宽则放弃（爆炸半径控制），
    # 在 plan 调用之前拦截，省一次 API。
    if old_len > MAX_SPAN_M * 2.0:
        attempts.append({"interval": [lo, hi], "reject": "snap_too_wide",
                         "span_m": round(old_len, 1)})
        return None, 0, None

    repl = planner.plan_walking(p_start, p_end)
    calls = 1
    if repl.error or not repl.points or len(repl.points) < 2:
        attempts.append({"interval": [lo, hi], "reject": f"plan:{repl.error}"})
        return None, calls, None
    new_len = repl.distance_m
    saved = old_len - new_len
    old_turns = _count_geo_turns(old_slice)
    new_turns = _count_geo_turns(repl.points)
    if saved < MIN_SAVING_M:
        attempts.append({"interval": [lo, hi], "reject": "saving",
                         "old_m": round(old_len, 1), "new_m": round(new_len, 1)})
        return None, calls, None
    if new_turns > old_turns:
        attempts.append({"interval": [lo, hi], "reject": "turns",
                         "old_turns": old_turns, "new_turns": new_turns})
        return None, calls, None

    # ---- 拼接：折线 + steps + 段距离 ----
    # 逐 step 去重退化点，折线由 step 拼接再生，保证映射一致（导航文本可重建）
    new_steps: List[PlanStep] = []
    for st in repl.steps:
        pts = _dedup(st.polyline)
        if pts:
            new_steps.append(PlanStep(instruction=st.instruction, road=st.road,
                                      distance_m=st.distance_m, duration_s=st.duration_s,
                                      action=st.action, orientation=st.orientation,
                                      polyline=pts))
    repl_pts = [p for st in new_steps for p in st.polyline]
    if not repl_pts:
        repl_pts = _dedup(repl.points)
    new_poly = loop.polyline[:lo] + repl_pts + loop.polyline[hi + 1:]

    old_rep = repetition_ratio(loop.polyline)
    new_rep = repetition_ratio(new_poly)
    if new_rep > old_rep + 0.01:
        attempts.append({"interval": [lo, hi], "reject": "repetition",
                         "old_rep": round(old_rep, 3), "new_rep": round(new_rep, 3)})
        return None, calls, None

    new_dist = loop.distance_m - old_len + new_len

    # 容差感知模式（阶段 K：部分采用策略）：修复后若打破 ±tol 硬约束则拒绝，
    # 让调用方继续尝试其他区间——只摘「不破坏达标」的小绕行。
    if target_m is not None and abs(new_dist - target_m) > tol_m:
        attempts.append({"interval": [lo, hi], "reject": "tolerance",
                         "new_err": round(new_dist - target_m, 1)})
        return None, calls, None

    new_dur = loop.duration_s - sum(
        s.duration_s for s in _replaced_steps(loop, seg_a, step_a, seg_b, step_b)
    ) + repl.duration_s

    # 段重建：seg_a..seg_b 合并为单段（跨段替换时中间段的 steps 全部被换掉；
    # 且 seg_b 若被截断，其「段首点=上段末点」的拼接去重假设会被破坏，
    # 合并可保证 steps 拼接与折线严格一一对应，导航文本可重建）。
    seg_a_obj = loop.segments[seg_a]
    seg_b_obj = loop.segments[seg_b]
    merged_steps = (list(seg_a_obj.steps[:step_a]) + new_steps
                    + list(seg_b_obj.steps[step_b + 1:]))
    merged = RouteSegment(
        index=seg_a_obj.index, origin=seg_a_obj.origin,
        destination=seg_b_obj.destination,
        distance_m=sum(s.distance_m for s in merged_steps),
        duration_s=sum(s.duration_s for s in merged_steps),
        n_points=sum(len(s.polyline) for s in merged_steps),
        steps=merged_steps)
    new_segments = (list(loop.segments[:seg_a]) + [merged]
                    + list(loop.segments[seg_b + 1:]))
    closure = haversine(new_poly[0], new_poly[-1]) if len(new_poly) >= 2 else 0.0
    fixed = LoopRoute(
        distance_m=new_dist, duration_s=new_dur,
        closure_m=round(closure, 2), start_snap_m=loop.start_snap_m,
        polyline=new_poly, segments=new_segments)
    fix = SpurFix(span_m=round(old_len, 1), repl_m=round(new_len, 1),
                  saved_m=round(saved, 1), at=p_start,
                  old_turns=old_turns, new_turns=new_turns)
    return fixed, calls, fix


def _replaced_steps(loop: LoopRoute, seg_a: int, step_a: int,
                    seg_b: int, step_b: int) -> List[PlanStep]:
    out: List[PlanStep] = []
    for si, seg in enumerate(loop.segments):
        if si < seg_a or si > seg_b:
            continue
        if si == seg_a and si == seg_b:
            out.extend(seg.steps[step_a:step_b + 1])
        elif si == seg_a:
            out.extend(seg.steps[step_a:])
        elif si == seg_b:
            out.extend(seg.steps[:step_b + 1])
        else:
            out.extend(seg.steps)
    return out


def fix_spurs(loop: LoopRoute, planner: MapPlanner,
              max_fixes: int = MAX_FIXES, sleep: float = 0.0,
              target_m: Optional[float] = None,
              tol_m: float = 500.0) -> SpurFixResult:
    """对闭环做无效绕行替换（逐轮：检测→替换→重检测，索引安全）。

    返回修复后的新 LoopRoute（原对象不修改）、消耗的 API 调用数与修复记录。

    target_m=None（默认，激进模式）：接受一切通过结构守卫（更短/转弯不增/
    rep 不恶化）的修复，达标复检交给调用方（calibrator 走割线重校或回退）。
    target_m 给定（容差感知模式）：只接受修复后仍满足 |dist-target| <= tol_m
    的替换，其余记 reject="tolerance" 并尝试下一区间——用于「部分采用」。
    """
    calls = 0
    fixes: List[SpurFix] = []
    attempts: List[dict] = []
    cur = loop
    for _ in range(max_fixes):
        mapping = _build_index_map(cur)
        if mapping is None:
            attempts.append({"reject": "index_map"})
            break
        intervals = find_spur_intervals(cur.polyline)
        if not intervals:
            break
        fixed_one = False
        for iv in intervals:
            new_loop, c, fix = _try_fix_one(cur, mapping, iv, planner, attempts,
                                            target_m=target_m, tol_m=tol_m)
            calls += c
            if new_loop is not None and fix is not None:
                cur = new_loop
                fixes.append(fix)
                fixed_one = True
                break  # 折线已变，重新检测（映射失效）
            if sleep > 0:
                import time
                time.sleep(sleep)
        if not fixed_one:
            break
    return SpurFixResult(loop=cur, calls=calls, fixes=fixes, attempts=attempts)
