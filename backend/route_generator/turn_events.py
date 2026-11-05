#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统一转弯事件模型（P0 整改）。

背景（真实数据证据）：
- 旧 `nav_text.build_nav_instructions` 把「自身直行且 <40m」的步骤无脑并入
  上一步，跨过了真实的 90° 转弯与分段接缝。实测 1km 路线中，4 个真实转弯
  （含一个掉头）被合并成一条 121m 步骤，语音因此漏报直角左转。
- 旧服务端 `_downsample(points, 2)` 隔点抽稀把 1081m 折线压成 991m（-8%），
  地图几何被裁角，而语音仍使用高德步骤累计里程，两者基准不一致，造成
  「地图显示左转、语音说右转」以及转弯提示过晚。
- 分段闭环由多段独立高德步行规划拼接，接缝处会真实折返；必须作为事件
  显式表达，不能靠猜测吞掉。

本模块的唯一职责：给出一条折线的**唯一**转弯结论。地图图标、顶部提示、
TTS 文本全部消费同一个 TurnEvent，禁止任何一端自行再算一遍。

原则：
1. `at_m` 一律是**真实折线**（地图实际绘制的那条）上的累计里程；
2. 左右以「实际行进方向」为参照（方位角顺时针 0=北），与地图旋转无关；
3. 高德 action 与几何角度交叉验证：
   - 两者一致 → high；
   - 只有 action/只有几何 → medium；
   - 两者方向冲突 → 以 action 为准并标 low（客户端据此降级为一般提醒）。
4. 接缝折返（join=True）显式标注，供路线质量与客户端播报策略使用。
"""
import math
from typing import Dict, List, Optional, Sequence, Tuple

from .geo import GeoPoint, haversine
from .nav_text import action_kind, bearing
from .types import PlanStep, RouteSegment

# 角度分级（度）。真实道路 90° 转弯必须落入 turn，轻微弯曲不得误报。
STRAIGHT_MAX_DEG = 20.0
SLIGHT_MAX_DEG = 45.0
UTURN_MIN_DEG = 150.0

# 两个事件沿路线的最小间隔（米）：更近的视为同一次转向/抖动。
MIN_EVENT_SEP_M = 6.0
# 折线采样转弯方向时的前后臂长（米）。
_ARM_M = 12.0
# 直行路名变化的最小间隔（米），避免碎片步骤反复播报。
MIN_ROAD_CHANGE_M = 80.0


def signed_delta(enter_b: float, exit_b: float) -> float:
    """出射相对入射的有符号角差（+右 / -左），范围 (-180, 180]。"""
    return (exit_b - enter_b + 540.0) % 360.0 - 180.0


def geom_kind(delta: float) -> str:
    """几何角差 → 转向类别（无高德 action 时的兜底）。"""
    d = abs(delta)
    if d >= UTURN_MIN_DEG:
        return "uturn"
    if d >= SLIGHT_MAX_DEG:
        return "right" if delta > 0 else "left"
    # 20°~45° 的轻微弯曲不当作路口转弯，避免频繁误报。
    return "straight"


def cumulative_meters(points: Sequence[GeoPoint]) -> List[float]:
    cum: List[float] = [0.0]
    for i in range(1, len(points)):
        cum.append(cum[-1] + haversine(points[i - 1], points[i]))
    return cum


def point_at(points: Sequence[GeoPoint], cum: Sequence[float], d: float) -> GeoPoint:
    """折线上距离 d 处的插值点。"""
    if not points:
        return (0.0, 0.0)
    if len(points) == 1:
        return points[0]
    dd = max(0.0, min(float(d), cum[-1]))
    lo, hi = 0, len(cum) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cum[mid] < dd:
            lo = mid + 1
        else:
            hi = mid
    i = lo
    if i <= 0:
        return points[0]
    seg = cum[i] - cum[i - 1]
    t = 0.0 if seg <= 0 else (dd - cum[i - 1]) / seg
    a, b = points[i - 1], points[i]
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def _project_onto(points: Sequence[GeoPoint], cum: Sequence[float],
                  p: GeoPoint, hint: Optional[float], window_m: float = 80.0):
    """把点投影到折线上：返回 (along_m, offset_m, projected_point)。

    hint 存在时只在该里程窗口内搜索，避免去/返程重叠路段串腿。
    """
    n = len(points)
    if n == 0:
        return 0.0, float("inf"), p
    if n == 1:
        return 0.0, haversine(p, points[0]), points[0]
    if hint is None:
        i0, i1 = 0, n - 2
    else:
        lo = max(0.0, hint - window_m)
        hi = min(cum[-1], hint + window_m)
        i0 = 0
        while i0 < n - 2 and cum[i0 + 1] < lo:
            i0 += 1
        i1 = i0
        while i1 < n - 2 and cum[i1] < hi:
            i1 += 1
    cos_lat = math.cos(math.radians(p[1]))
    px, py = p[0] * cos_lat, p[1]
    best_along = cum[i0]
    best_off = float("inf")
    best_pt = points[i0]
    for i in range(i0, i1 + 1):
        a, b = points[i], points[i + 1]
        ax, ay = a[0] * cos_lat, a[1]
        dx, dy = b[0] * cos_lat - ax, b[1] - ay
        len2 = dx * dx + dy * dy
        t = 0.0 if len2 <= 0 else ((px - ax) * dx + (py - ay) * dy) / len2
        t = max(0.0, min(1.0, t))
        proj = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        off = haversine(p, proj)
        if off < best_off:
            best_off = off
            best_pt = proj
            best_along = cum[i] + (cum[i + 1] - cum[i]) * t
    return best_along, best_off, best_pt


def _bearing_arm(points: Sequence[GeoPoint], cum: Sequence[float],
                 d: float, arm: float = _ARM_M) -> Optional[float]:
    """以 d 为中心，用前后臂计算进入/离开方位角。"""
    if cum[-1] <= 0:
        return None
    a0 = max(0.0, d - arm)
    a1 = max(0.0, d - 2.0)
    b0 = min(cum[-1], d + 2.0)
    b1 = min(cum[-1], d + arm)
    if a1 - a0 < 1.0 or b1 - b0 < 1.0:
        return None
    enter_b = bearing(point_at(points, cum, a0), point_at(points, cum, a1))
    exit_b = bearing(point_at(points, cum, b0), point_at(points, cum, b1))
    return signed_delta(enter_b, exit_b)


def _step_end(st: PlanStep) -> Optional[GeoPoint]:
    if st.polyline:
        return st.polyline[-1]
    return None


def _step_start(st: PlanStep) -> Optional[GeoPoint]:
    if st.polyline:
        return st.polyline[0]
    return None


def _step_enter_bearing(st: PlanStep) -> Optional[float]:
    if len(st.polyline) >= 2:
        return bearing(st.polyline[0], st.polyline[1])
    return None


def _step_exit_bearing(st: PlanStep) -> Optional[float]:
    if len(st.polyline) >= 2:
        return bearing(st.polyline[-2], st.polyline[-1])
    return None


def _road_parts(flat: List[Tuple[PlanStep, int]], i: int) -> Tuple[str, str]:
    """返回 (当前道路, 转弯后道路)。空路名向前/向后顺延，避免把路名说错。"""
    road_from = (flat[i][0].road or "").strip()
    j = i
    while not road_from and j > 0:
        j -= 1
        road_from = (flat[j][0].road or "").strip()
    road_to = ""
    for k in range(i + 1, min(i + 4, len(flat))):
        r = (flat[k][0].road or "").strip()
        if r:
            road_to = r
            break
    return road_from, road_to


def _priority(e: Dict) -> Tuple[int, int, float]:
    conf = {"high": 3, "medium": 2, "low": 1}.get(e.get("confidence"), 0)
    turn = 1 if e.get("kind") in ("left", "right", "uturn") else 0
    return conf, turn, float(e.get("angle_deg") or 0)


def build_turn_events(segments: Sequence[RouteSegment],
                      polyline: Sequence[GeoPoint]) -> List[Dict]:
    """从真实分段 steps + canonical 折线生成唯一转弯事件列表。

    返回字段（客户端契约）：
      id, at_m, angle_deg, signed_deg, kind, announce, road_from, road_to,
      junction [lng,lat], step_index, segment_index, join, source, confidence
    """
    if not polyline or len(polyline) < 2:
        return []

    flat: List[Tuple[PlanStep, int]] = []
    for si, seg in enumerate(segments):
        for st in seg.steps:
            flat.append((st, si))
    if not flat:
        return [{"id": "end", "at_m": round(cumulative_meters(polyline)[-1], 1),
                 "kind": "end", "announce": False, "confidence": "high"}]

    cum_poly = cumulative_meters(polyline)
    poly_total = cum_poly[-1]
    step_total = sum(max(0.0, float(st.distance_m or 0.0)) for st, _ in flat)
    if step_total <= 0:
        step_total = poly_total
    scale = (poly_total / step_total) if step_total > 0 else 1.0

    # 每个步骤结束处的“原始累计里程”（用于投影 hint，解决去/返重叠）
    step_cum: List[float] = []
    acc = 0.0
    for st, _ in flat:
        d = float(st.distance_m or 0.0)
        if d <= 0 and len(st.polyline) >= 2:
            d = sum(haversine(st.polyline[k - 1], st.polyline[k])
                    for k in range(1, len(st.polyline)))
        acc += d
        step_cum.append(acc)

    raw: List[Dict] = []
    last_announced_m = -1e9
    for i, (st, si) in enumerate(flat):
        if i + 1 >= len(flat):
            raw.append({
                "id": f"t{i}", "at_m": round(poly_total, 1),
                "angle_deg": 0.0, "signed_deg": 0.0, "kind": "end",
                "announce": False, "road_from": (st.road or "").strip(),
                "road_to": "", "junction": list(_step_end(st) or polyline[-1]),
                "step_index": i, "segment_index": si, "join": False,
                "source": "end", "confidence": "high",
            })
            continue

        nxt = flat[i + 1][0]
        nxt_si = flat[i + 1][1]
        junction = _step_end(st) or _step_start(nxt)
        if junction is None:
            continue

        hint = step_cum[i] * scale
        at_m, offset, proj_pt = _project_onto(polyline, cum_poly, junction, hint)
        if offset > 40.0 and hint is not None:
            # 投影不可靠（去/返程同一坐标）→ 用里程比例兜底，但保留真实折线里程语义
            at_m = max(0.0, min(poly_total, hint))

        enter_b = _step_enter_bearing(st)
        exit_b = _step_exit_bearing(st)
        next_enter = _step_enter_bearing(nxt)
        raw_delta: Optional[float] = None
        if exit_b is not None and next_enter is not None:
            raw_delta = signed_delta(exit_b, next_enter)
        poly_delta = _bearing_arm(polyline, cum_poly, at_m)

        # 选择几何角差：两源都可用时取更“像转弯”的一个（避免短边噪声），
        # 方向冲突时优先真实折线（地图画出来的就是它）。
        if poly_delta is None:
            delta = raw_delta
            delta_src = "steps"
        elif raw_delta is None:
            delta = poly_delta
            delta_src = "polyline"
        else:
            if geom_kind(raw_delta) == geom_kind(poly_delta):
                delta = raw_delta if abs(raw_delta) >= abs(poly_delta) else poly_delta
                delta_src = "both"
            elif abs(poly_delta) >= abs(raw_delta):
                delta = poly_delta
                delta_src = "polyline"
            else:
                delta = raw_delta
                delta_src = "steps"

        act = action_kind(st.action)
        gk = geom_kind(delta) if delta is not None else "straight"

        if act:
            kind = act
            if gk == act:
                confidence = "high"
            elif gk == "straight":
                confidence = "medium"  # 短步骤/密集折线可能看不到角
            else:
                confidence = "low"     # 左/右冲突：以高德结构化 action 为准
        else:
            kind = gk
            confidence = "medium" if abs(delta or 0.0) >= SLIGHT_MAX_DEG else "low"

        join = si != nxt_si
        source = "action+geometry" if act and gk == act else (
            "action" if act else ("segment_join" if join else delta_src))

        road_from, road_to = _road_parts(flat, i)
        announce = kind in ("left", "right", "uturn")
        # 直行只在路名真正变化时提示一次（供“沿 X 路继续直行”）。
        if kind == "straight" and road_to and road_from and road_to != road_from:
            if at_m - last_announced_m >= MIN_ROAD_CHANGE_M:
                announce = True
                source = "road_change"
        if kind == "straight" and not announce:
            continue
        if announce:
            last_announced_m = at_m

        raw.append({
            "id": f"t{i}",
            "at_m": round(at_m, 1),
            "angle_deg": round(abs(delta or 0.0), 1),
            "signed_deg": round(float(delta or 0.0), 1),
            "kind": kind,
            "announce": bool(announce),
            "road_from": road_from,
            "road_to": road_to,
            "junction": [round(proj_pt[0], 6), round(proj_pt[1], 6)],
            "step_index": i,
            "segment_index": si,
            "join": bool(join),
            "source": source,
            "confidence": confidence,
        })

    # 去重：6m 内只保留置信度/角度更高的事件；90° 真转弯优先于接缝伪掉头。
    raw.sort(key=lambda e: (e["at_m"], -_priority(e)[0], -_priority(e)[2]))
    out: List[Dict] = []
    for e in raw:
        if out and e["at_m"] - out[-1]["at_m"] < MIN_EVENT_SEP_M:
            if _priority(e) > _priority(out[-1]):
                out[-1] = e
            continue
        out.append(e)
    out.sort(key=lambda e: e["at_m"])
    return out


def events_to_steps(events: Sequence[Dict], polyline: Sequence[GeoPoint]) -> List[Dict]:
    """把事件折算成客户端兼容的 turns 摘要（不含 steps）。"""
    out = []
    for e in events:
        out.append({
            "id": e.get("id"),
            "at_m": e.get("at_m"),
            "angle_deg": e.get("angle_deg"),
            "signed_deg": e.get("signed_deg"),
            "kind": e.get("kind"),
            "announce": bool(e.get("announce", False)),
            "road_from": e.get("road_from", ""),
            "road_to": e.get("road_to", ""),
            "junction": e.get("junction"),
            "step_index": e.get("step_index"),
            "join": bool(e.get("join", False)),
            "source": e.get("source", ""),
            "confidence": e.get("confidence", "low"),
        })
    return out
