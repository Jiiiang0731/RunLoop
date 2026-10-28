#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""距离校准：按比例缩放环半径 R，使闭环总距离逼近目标距离。"""
import random
from typing import List

from .control_points import generate_ring
from .geo import GeoPoint
from .loop_builder import build_loop
from .planner import MapPlanner
from .types import CalibrateResult


def calibrate(planner: MapPlanner, start: GeoPoint, target_m: int, n_points: int,
              seed: int, tol_m: int = 500, max_iters: int = 8,
              detour_factor: float = 1.7, sleep: float = 0.0,
              jitter: float = 0.15) -> CalibrateResult:
    """
    对单个种子做 R 缩放迭代，返回距离最接近目标的闭环。

    - 初始 R = target / (2π * detour_factor)：detour_factor 为城市步行绕行系数（实测 ≈1.7）。
    - 每轮用同一 seed 生成环骨架（保持形状，只缩放 R），保证迭代单调可预测。
    - 失败时抖动 R 后重试；任一轮段失败仅记录，不影响其它轮。
    """
    R = target_m / (2 * 3.141592653589793 * detour_factor)
    best = None
    best_err = None
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
            best, best_err = loop, abs(e)
        if abs(e) <= tol_m:
            break
        factor = target_m / max(loop.distance_m, 1.0)
        R = R * (1 + 0.6 * (factor - 1))
    return CalibrateResult(loop=best, best_error_m=best_err, api_calls=calls, history=history)
