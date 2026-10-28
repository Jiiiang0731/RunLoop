#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""闭环组装：依次连接 起点 -> 控制点... -> 起点，拼接折线并计算闭合误差。"""
import time
from typing import List, Tuple

from .geo import GeoPoint, haversine
from .planner import MapPlanner
from .types import LoopRoute, RouteSegment


def build_loop(planner: MapPlanner, start: GeoPoint, waypoints: List[GeoPoint],
               sleep: float = 0.0) -> Tuple[LoopRoute, int]:
    """返回 (LoopRoute, api调用次数)。任一段规划失败则返回带 error 的 LoopRoute。"""
    seq = [start] + list(waypoints) + [start]
    total = 0.0
    duration = 0.0
    allpts: List[GeoPoint] = []
    segments: List[RouteSegment] = []
    calls = 0
    for i in range(len(seq) - 1):
        r = planner.plan_walking(seq[i], seq[i + 1])
        calls += 1
        if r.error:
            return LoopRoute(
                distance_m=total, duration_s=duration, closure_m=0.0, start_snap_m=0.0,
                polyline=allpts, segments=segments,
                error=f"segment[{i}] {seq[i]}->{seq[i + 1]}: {r.error}",
            ), calls
        total += r.distance_m
        duration += r.duration_s
        if r.points:
            if allpts:
                # 去掉与上一段共享的端点，避免重复点
                allpts.extend(r.points[1:] if len(r.points) > 1 else r.points)
            else:
                allpts.extend(r.points)
        segments.append(RouteSegment(index=i, origin=seq[i], destination=seq[i + 1],
                                     distance_m=r.distance_m, duration_s=r.duration_s,
                                     n_points=len(r.points)))
        if sleep > 0:
            time.sleep(sleep)
    closure = haversine(allpts[0], allpts[-1]) if len(allpts) >= 2 else 0.0
    snap = haversine(start, allpts[0]) if allpts else 0.0
    return LoopRoute(
        distance_m=total, duration_s=duration,
        closure_m=round(closure, 2), start_snap_m=round(snap, 2),
        polyline=allpts, segments=segments,
    ), calls
