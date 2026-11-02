#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""顶层编排：按多个种子生成候选环线，逐条校准、计算质量指标并评分。

阶段 J 优化：
- 校准内部做「骨架变体扫描 + 质量选择」（少转弯椭圆骨架优先），见 calibrator；
- 每种子传入剩余 API 预算，防止单种子耗尽全局预算；
- 候选按评分降序排序，最优达标候选标记 recommended（App 默认选中）。

阶段 I 保留：
- 自适应控制点数量（随目标距离 5~10 个）；
- max_candidates：成功生成到 N 条即停；
- max_api_calls：HTTP 调用硬预算；
- stage_times：记录每个种子耗时。
"""
import time
from typing import List

from .calibrator import calibrate
from .geo import GeoPoint
from .nav_metrics import analyze_route
from .planner import MapPlanner
from .scorer import score_route
from .types import Candidate, GenerateOptions, GenerateResult


def adaptive_n_points(target_m: int) -> int:
    """按目标距离选择控制点数量（实测标定）。

    蔡甸区实测：15km 用 7 个点会因骨架形状无法跨过距离断层而失败（+1217m），
    8 个点则 9.2s/35 次调用达标（-390m）；点太多（10）会更慢。
    因此 5km→5、10km→6、15km→9、20km→10。
    """
    km = target_m / 1000.0
    if km <= 7:
        return 5
    if km <= 12:
        return 6
    if km <= 17:
        return 9
    return 10


def rank_candidates(candidates: List[Candidate]) -> List[Candidate]:
    """达标候选按评分降序置顶并标记 recommended；失败候选保持原顺序置后。"""
    ok = [c for c in candidates if c.error is None and c.loop is not None and c.score is not None]
    bad = [c for c in candidates if c not in ok]
    ok.sort(key=lambda c: c.score.total, reverse=True)
    for c in candidates:
        c.recommended = False
    if ok:
        ok[0].recommended = True
    return ok + bad


def generate_candidates(planner: MapPlanner, start: GeoPoint,
                        options: GenerateOptions) -> GenerateResult:
    """为每个种子生成一条候选路线，返回带评分与失败信息的完整结果（最优置顶）。"""
    t_all = time.time()
    candidates: List[Candidate] = []
    stage_times: dict = {}
    ok_count = 0
    http_start = getattr(planner, "http_calls", 0)
    n_points = options.n_points or adaptive_n_points(options.target_m)

    for seed in options.seeds:
        if ok_count >= options.max_candidates:
            break
        used = getattr(planner, "http_calls", 0) - http_start
        remaining = options.max_api_calls - used
        if remaining <= 0:
            break
        per_seed = min(remaining, max(30, options.per_seed_calls))
        t0 = time.time()
        cr = calibrate(
            planner, start, options.target_m, n_points, seed,
            tol_m=options.tol_m, max_iters=options.max_iters,
            detour_factor=options.detour_factor, sleep=options.sleep_s,
            jitter=options.jitter, max_calls=per_seed,
        )
        dt = round(time.time() - t0, 2)
        stage_times[f"seed_{seed}"] = dt
        if cr.loop is None or cr.loop.error:
            candidates.append(Candidate(
                seed=seed, loop=cr.loop, score=None, api_calls=cr.api_calls,
                elapsed_s=dt, history=cr.history,
                error=(cr.loop.error if cr.loop else "无法生成闭环")))
        else:
            metrics = cr.best_metrics
            if metrics is None:
                all_steps = []
                for seg in cr.loop.segments:
                    all_steps.extend(seg.steps)
                metrics = analyze_route(all_steps, cr.loop.polyline, options.target_m)
            ok_count += 1
            candidates.append(Candidate(
                seed=seed, loop=cr.loop,
                score=score_route(options.target_m, cr.loop, metrics),
                api_calls=cr.api_calls, elapsed_s=dt, history=cr.history,
                metrics=metrics))

    total_http = getattr(planner, "http_calls", 0) - http_start
    return GenerateResult(
        target_m=options.target_m, start=start,
        candidates=rank_candidates(candidates),
        total_api_calls=total_http, total_elapsed_s=round(time.time() - t_all, 2),
        stage_times=stage_times)
