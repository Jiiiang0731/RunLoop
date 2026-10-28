#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""顶层编排：按多个种子生成候选环线，逐条校准并评分。"""
import time
from typing import List

from .calibrator import calibrate
from .geo import GeoPoint
from .planner import MapPlanner
from .scorer import score_route
from .types import Candidate, GenerateOptions, GenerateResult


def generate_candidates(planner: MapPlanner, start: GeoPoint,
                        options: GenerateOptions) -> GenerateResult:
    """为每个种子生成一条候选路线，返回带评分与失败信息的完整结果。"""
    t_all = time.time()
    candidates: List[Candidate] = []
    total_calls = 0
    for seed in options.seeds:
        t0 = time.time()
        cr = calibrate(
            planner, start, options.target_m, options.n_points, seed,
            tol_m=options.tol_m, max_iters=options.max_iters,
            detour_factor=options.detour_factor, sleep=options.sleep_s,
            jitter=options.jitter,
        )
        total_calls += cr.api_calls
        dt = round(time.time() - t0, 2)
        if cr.loop is None or cr.loop.error:
            candidates.append(Candidate(
                seed=seed, loop=cr.loop, score=None, api_calls=cr.api_calls,
                elapsed_s=dt, history=cr.history,
                error=(cr.loop.error if cr.loop else "无法生成闭环")))
        else:
            candidates.append(Candidate(
                seed=seed, loop=cr.loop, score=score_route(options.target_m, cr.loop),
                api_calls=cr.api_calls, elapsed_s=dt, history=cr.history))
    return GenerateResult(
        target_m=options.target_m, start=start, candidates=candidates,
        total_api_calls=total_calls, total_elapsed_s=round(time.time() - t_all, 2))
