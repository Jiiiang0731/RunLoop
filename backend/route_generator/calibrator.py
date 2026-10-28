#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""距离校准：按比例缩放环半径 R，使闭环总距离逼近目标距离。

改进（阶段 D）：当 R 缩放无法达标时（路网导致距离对 R 是跳变函数），
增加「角度精修」——旋转环骨架（改变控制点落点），以跨过距离断层。
"""
import math
import random
from typing import List, Optional

from .control_points import generate_ring
from .geo import GeoPoint
from .loop_builder import build_loop
from .planner import MapPlanner
from .types import CalibrateResult

# 精修时尝试的环骨架旋转角度（度）
_REFINE_ANGLES = (30.0, 75.0, 120.0, 165.0, 210.0, 255.0)


def calibrate(planner: MapPlanner, start: GeoPoint, target_m: int, n_points: int,
              seed: int, tol_m: int = 500, max_iters: int = 8,
              detour_factor: float = 1.7, sleep: float = 0.0,
              jitter: float = 0.15) -> CalibrateResult:
    """
    对单个种子做 R 缩放迭代 + 角度精修，返回距离最接近目标的闭环。

    - 初始 R = target / (2π * detour_factor)。
    - 每轮用同一 seed 生成环骨架（保持形状，只缩放 R）。
    - 若主循环未达标，在最佳 R 上旋转环骨架（_REFINE_ANGLES）尝试更接近的形状。
    - 失败时抖动 R 后重试。
    """
    R = target_m / (2 * math.pi * detour_factor)
    best = None
    best_err: Optional[float] = None
    best_R: Optional[float] = None
    calls = 0
    history: List[dict] = []

    for it in range(max_iters):
        wps = generate_ring(start, R, n_points, seed, jitter=jitter)
        loop, c = build_loop(planner, start, wps, sleep=sleep)
        calls += c
        if loop.error:
            history.append({"iter": it, "R": round(R, 1), "error": loop.error})
            R = R * random.Random(seed * 131 + it).uniform(0.9, 1.15)
            continue
        e = loop.distance_m - target_m
        history.append({"iter": it, "R": round(R, 1), "distance": round(loop.distance_m, 1),
                        "err": round(e, 1), "closure_m": loop.closure_m})
        if best is None or abs(e) < best_err:
            best, best_err, best_R = loop, abs(e), R
        if abs(e) <= tol_m:
            break
        factor = target_m / max(loop.distance_m, 1.0)
        R = R * (1 + 0.6 * (factor - 1))

    # 角度精修：主循环未达标时，旋转环骨架搜索能跨过距离断层的形状。
    if best is not None and best_err is not None and best_err > tol_m and best_R is not None:
        for idx, angle in enumerate(_REFINE_ANGLES):
            wps = generate_ring(start, best_R, n_points, seed, jitter=jitter, angle_deg=angle)
            loop, c = build_loop(planner, start, wps, sleep=sleep)
            calls += c
            if loop.error:
                history.append({"refine": idx, "angle": angle, "error": loop.error})
                continue
            e = loop.distance_m - target_m
            history.append({"refine": idx, "angle": angle, "distance": round(loop.distance_m, 1),
                            "err": round(e, 1), "closure_m": loop.closure_m})
            if abs(e) < best_err:
                best, best_err = loop, abs(e)
            if abs(e) <= tol_m:
                break

    return CalibrateResult(loop=best, best_error_m=best_err, api_calls=calls, history=history)
