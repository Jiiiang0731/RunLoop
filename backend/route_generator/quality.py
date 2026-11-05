#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：把「道路连续性」「道路安全」「车流暴露」「机动车可通行性」分开。

数据边界（必须如实）：
- 高德 Web 服务不提供真实照明、实时车流、道路宽度数据；因此本模块
  **不生成**道路安全分 / 车流暴露分，只把缺失原因写清楚。
- `walk_type` 只按官方已确认取值解释；真实 API 返回的未收录取值
  （本项目实测到 20）原样列为 unclassified，不猜测、不参与打分。
- 机动车可通行率只是「道路等级/连通性」的辅助代理，不是安全、不是车流。

道路连续性分只由真实步行 steps 的结构指标推导（闭合/转弯/长直行/重复），
它与「安全」不是同一个概念，API 中必须分开呈现。
"""
from typing import Dict, List, Optional

from .scorer import (
    closure_score, long_straight_score, repetition_score, turn_density_score,
)
from .types import LoopRoute, PlanStep

# 官方步行路径规划 steps.walk_type 已确认取值（截至取证时文档只列到 11）。
# 2 不在官方取值中，禁止把 2 猜成地下通道；未知值统一 unclassified。
WALK_TYPE_LABELS: Dict[str, str] = {
    "0": "普通道路",
    "1": "人行横道",
    "3": "地下通道",
    "4": "过街天桥",
    "5": "地铁通道",
    "6": "公园",
    "7": "广场",
    "8": "扶梯",
    "9": "直梯",
    "10": "索道",
    "11": "空中通道",
}

# 已确认的「非地面/需上下设施」类型：只作为结构事实统计，不作为安全分。
WALK_TYPE_GRADE_SEPARATED = frozenset({"3", "4", "5", "8", "9", "10", "11"})


def walk_type_profile(steps: List[PlanStep], total_m: float) -> Dict:
    """按真实 walk_type 统计步数与距离；未知取值单独列出，不猜。"""
    counts: Dict[str, int] = {}
    dist: Dict[str, float] = {}
    missing = 0
    for st in steps or []:
        wt = (getattr(st, "walk_type", "") or "").strip()
        if not wt:
            missing += 1
            continue
        counts[wt] = counts.get(wt, 0) + 1
        dist[wt] = round(dist.get(wt, 0.0) + (st.distance_m or 0.0), 1)

    grade_m = sum(dist.get(k, 0.0) for k in WALK_TYPE_GRADE_SEPARATED)
    unclassified = {k: v for k, v in counts.items() if k not in WALK_TYPE_LABELS}
    unclassified_m = {k: dist.get(k, 0.0) for k in unclassified}
    return {
        "source": "amap_walking_steps.walk_type",
        "labels": {k: WALK_TYPE_LABELS.get(k, "unclassified") for k in counts},
        "counts": counts,
        "distance_m": dist,
        "grade_separated_distance_m": round(grade_m, 1),
        "grade_separated_ratio": (round(grade_m / total_m, 3)
                                  if total_m and total_m > 0 else 0.0),
        "unclassified_counts": unclassified,
        "unclassified_distance_m": unclassified_m,
        "missing_walk_type_steps": missing,
        "note": ("已确认取值 0/1/3/4/5/6/7/8/9/10/11；未收录值（如实测 20）"
                 "只上报、不解释、不参与评分"),
    }


def road_continuity(loop: LoopRoute, metrics: Optional[Dict]) -> Dict:
    """道路连续性（真实步行结构指标），与安全性无关。"""
    m = metrics or {}
    if not m or "turn_density" not in m:
        return {
            "available": False,
            "score": None,
            "reason": "缺少真实步行 steps 结构指标",
            "note": "道路连续性分不是安全分",
        }
    parts = [
        ("closure", closure_score(float(loop.closure_m or 0.0)), 0.40,
         f"闭合缺口 {float(loop.closure_m or 0.0):.1f}m"),
        ("turn_density", turn_density_score(float(m.get("turn_density", 2.0))), 0.25,
         f"{int(m.get('turns', 0))} 次转弯，{float(m.get('turn_density', 0)):.2f} 次/km"),
        ("long_straight", long_straight_score(m), 0.20,
         f"最长直行 {float(m.get('straight_max_m', 0)):.0f}m"),
        ("repetition", repetition_score(float(m.get("repetition_ratio", 0.0))), 0.15,
         f"重复路段 {float(m.get('repetition_ratio', 0)):.1%}"),
    ]
    total = sum(score * weight for _, score, weight, _ in parts)
    return {
        "available": True,
        "score": round(total, 1),
        "basis": "amap_walking_steps_geometry",
        "components": [
            {"name": name, "score": round(score, 1), "weight": weight, "detail": detail}
            for name, score, weight, detail in parts
        ],
        "note": ("结构连续性：闭合/转弯密度/长直行/重复路段；"
                 "不评价照明、车流、路宽，也不代表安全"),
    }


def _road_safety(profile: Dict) -> Dict:
    return {
        "available": False,
        "score": None,
        "reason": "缺少真实照明、实时车流、道路宽度数据；不生成安全分",
        "partial_observations": {
            "walk_type_grade_separated_ratio": profile.get("grade_separated_ratio"),
            "walk_type_unclassified_counts": profile.get("unclassified_counts"),
        },
        "note": ("地下通道/天桥等 walk_type 只是设施类型事实；"
                 "机动车可通行率也只是道路等级代理，均不能替代安全评估"),
    }


def _traffic_exposure(profile: Dict) -> Dict:
    return {
        "available": False,
        "score": None,
        "reason": "缺少实时车流、车速、道路宽度数据；不生成车流暴露分",
        "not_inferred_from": ["drivable_ratio", "road_class_proxy", "walk_type"],
        "note": ("不会用『车能通过』推断车流量或暴露风险；"
                 "需要真实交通数据源后才可评估"),
    }


def _drivable_access(drivable: Optional[Dict]) -> Dict:
    if not drivable:
        return {
            "available": False,
            "score": None,
            "reason": "本次未请求 verify_drivable；不做驾车可通行率核验",
            "use_for": ["road_connectivity_support", "road_class_proxy"],
            "not_for": ["safety", "traffic_exposure"],
        }
    if not drivable.get("available"):
        return {
            "available": False,
            "score": None,
            "reason": drivable.get("reason") or "驾车可通行性未获取",
            "segments": drivable.get("segments", []),
            "use_for": ["road_connectivity_support", "road_class_proxy"],
            "not_for": ["safety", "traffic_exposure"],
        }
    return {
        "available": True,
        "score": None,
        "walking_m": drivable.get("walking_m"),
        "driving_m": drivable.get("driving_m"),
        "driving_to_walking_ratio": drivable.get("driving_to_walking_ratio"),
        "segments_ok": drivable.get("segments_ok"),
        "segments_total": drivable.get("segments_total"),
        "partial": drivable.get("partial", False),
        "segments": drivable.get("segments", []),
        "use_for": ["road_connectivity_support", "road_class_proxy"],
        "not_for": ["safety", "traffic_exposure"],
        "note": ("仅表示机动车能否按相近路径通行，作为道路等级/连通性的辅助；"
                 "不代表照明、车流、路宽或跑步安全"),
    }


def build_quality(loop: LoopRoute, metrics: Optional[Dict],
                  drivable: Optional[Dict] = None) -> Dict:
    """返回分离的质量块；安全/车流不可用时明确返回 available=False。"""
    m = metrics or {}
    profile = m.get("walk_type_profile") or walk_type_profile([], loop.distance_m)
    return {
        "road_continuity": road_continuity(loop, m),
        "road_safety": _road_safety(profile),
        "traffic_exposure": _traffic_exposure(profile),
        "motor_vehicle_access": _drivable_access(drivable),
        "walk_type": profile,
        "data_gaps": [
            "lighting",
            "realtime_traffic",
            "road_width",
        ],
        "scoring_policy": ("安全/车流无真实数据时不合成分数；"
                           "连续性分与驾车可通行率分开展示"),
    }


def compute_drivable_access(planner, loop: LoopRoute, max_calls: int = 20) -> Dict:
    """逐段真实驾车规划，计算驾车/步行里程比（辅助道路等级，不是安全）。

    只使用 loop.segments（真实控制点/锚点分段）；失败段如实标记，不补齐。
    """
    if not loop or not loop.segments:
        return {"available": False, "reason": "没有可核验的路线分段",
                "segments": [], "api_calls": 0}
    if not hasattr(planner, "plan_driving"):
        return {"available": False, "reason": "规划器不支持驾车核验",
                "segments": [], "api_calls": 0}

    start_calls = getattr(planner, "http_calls", 0)
    rows = []
    walk_total = 0.0
    drive_total = 0.0
    ok = 0
    for seg in loop.segments:
        used = getattr(planner, "http_calls", 0) - start_calls
        if used >= max_calls:
            rows.append({"index": seg.index, "ok": False,
                         "error": "driver_call_budget_exhausted"})
            continue
        r = planner.plan_driving(seg.origin, seg.destination)
        row = {
            "index": seg.index,
            "walking_m": round(seg.distance_m, 1),
            "driving_m": round(r.distance_m, 1) if r.ok else None,
            "ok": bool(r.ok and r.distance_m > 0),
            "error": r.error,
        }
        if row["ok"]:
            ok += 1
            walk_total += seg.distance_m
            drive_total += r.distance_m
            row["ratio"] = round(r.distance_m / seg.distance_m, 3) if seg.distance_m else None
        rows.append(row)

    api_calls = getattr(planner, "http_calls", 0) - start_calls
    if ok == 0:
        return {"available": False, "reason": "所有分段的驾车规划均失败",
                "segments": rows, "api_calls": api_calls,
                "segments_ok": 0, "segments_total": len(loop.segments)}
    return {
        "available": True,
        "walking_m": round(walk_total, 1),
        "driving_m": round(drive_total, 1),
        "driving_to_walking_ratio": round(drive_total / walk_total, 3) if walk_total else None,
        "segments_ok": ok,
        "segments_total": len(loop.segments),
        "partial": ok < len(loop.segments),
        "segments": rows,
        "api_calls": api_calls,
    }
