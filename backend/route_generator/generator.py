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

from .anchor_loop import build_anchor_loop
from .calibrator import calibrate
from .geo import GeoPoint
from .nav_metrics import analyze_route
from .planner import MapPlanner
from .scorer import score_route
from .types import Candidate, GenerateOptions, GenerateResult


def adaptive_n_points(target_m: int) -> int:
    """按目标距离选择控制点数量（实测标定）。

    阶段 N：≤3km 用 8 点——街区/校园尺度需要足够拐点贴合真实路网，
    5 点在 1km 目标下会让每段长约 110m，只能贴墙穿巷（实测 586m/−41%）。
    长距离沿用阶段 J/K 标定：5km→5、10km→6、15km→9、20km→10。
    """
    km = target_m / 1000.0
    # P1 实测（长江大学 1km，真实 API）：6 点骨架 1030m/42 次/15.9s，
    # 8 点骨架 1076m/70 次/19.2s；6 点同时把转弯 12→9、接缝短折返 2→0。
    # 1.5km 以内用 6 点；1.5~3km 仍用 8 点，避免破坏短中距离精度。
    if target_m <= 1500:
        return 6
    if km <= 3:
        return 8
    if km <= 7:
        return 5
    if km <= 12:
        return 6
    if km <= 17:
        return 9
    return 10


def rank_candidates(candidates: List[Candidate], target_m: int = None,
                    tol_m: float = None) -> List[Candidate]:
    """达标候选按评分降序置顶并标记 recommended；失败候选保持原顺序置后。

    阶段 N：传入 target/tol 时，**距离达标者优先于未达标者**——避免长距离
    场景里「评分略高但超出 ±tol」的候选压过真正达标的候选。
    """
    ok = [c for c in candidates if c.error is None and c.loop is not None and c.score is not None]
    bad = [c for c in candidates if c not in ok]
    if target_m is not None and tol_m is not None:
        within = [c for c in ok
                  if abs(c.loop.distance_m - target_m) <= tol_m]
        outside = [c for c in ok if c not in within]
        within.sort(key=lambda c: c.score.total, reverse=True)
        outside.sort(key=lambda c: c.score.total, reverse=True)
        ok = within + outside
    else:
        ok.sort(key=lambda c: c.score.total, reverse=True)
    for c in candidates:
        c.recommended = False
    if ok:
        ok[0].recommended = True
    return ok + bad


def _generate_anchor(planner: MapPlanner, start: GeoPoint,
                     options: GenerateOptions) -> GenerateResult:
    """阶段 N：锚点模式（有序参考锚点 → 真实道路闭环 → 多拐点裁剪）。

    与骨架模式共用 Candidate / 序列化契约；额外带 anchor 信息。
    距离不达标时仍返回真实闭环候选（within_tolerance=false），绝不切割折线。
    """
    t0 = time.time()
    calls0 = getattr(planner, "http_calls", 0)
    seed = options.seeds[0] if options.seeds else 1
    cr = build_anchor_loop(planner, options.anchors, options.target_m,
                           tol_m=options.tol_m,
                           max_drop_total=options.max_drop_total)
    dt = round(time.time() - t0, 2)
    calls = getattr(planner, "http_calls", 0) - calls0
    loop = cr.get("loop")
    if loop is None or loop.error:
        cand = Candidate(
            seed=seed, loop=loop, score=None, api_calls=calls, elapsed_s=dt,
            history=[], error=cr.get("error") or (loop.error if loop else "无法生成锚点闭环"))
        return GenerateResult(
            target_m=options.target_m, start=start, candidates=[cand],
            total_api_calls=calls, total_elapsed_s=dt,
            stage_times={"anchor_loop": dt})

    metrics = (cr.get("best") or {}).get("metrics")
    if metrics is None:
        steps = [s for seg in loop.segments for s in seg.steps]
        metrics = analyze_route(steps, loop.polyline, options.target_m,
                                segments=loop.segments)
    score = score_route(options.target_m, loop, metrics)
    best = cr.get("best") or {}
    anchor = {
        "mode": "anchor_loop",
        "anchors_input": len(options.anchors),
        "anchors_used": cr.get("anchors_used"),
        "drops": best.get("drops") or [],
        "drop_index": best.get("drop"),
        "closure_m": loop.closure_m,
        "closure_ok": loop.error is None,
        "within_tolerance": abs(loop.distance_m - options.target_m) <= options.tol_m,
        "tried_candidates": len(cr.get("candidates") or []),
        "candidates_total": len(cr.get("candidates") or []),
        # 只回传前 12 个候选摘要，避免响应体随组合数膨胀
        "candidates": (cr.get("candidates") or [])[:12],
    }
    cand = Candidate(seed=seed, loop=loop, score=score, api_calls=calls,
                     elapsed_s=dt, history=[], metrics=metrics,
                     anchor=anchor, recommended=True)
    return GenerateResult(
        target_m=options.target_m, start=start, candidates=[cand],
        total_api_calls=calls, total_elapsed_s=dt,
        stage_times={"anchor_loop": dt})


def generate_candidates(planner: MapPlanner, start: GeoPoint,
                        options: GenerateOptions) -> GenerateResult:
    """为每个种子生成一条候选路线，返回带评分与失败信息的完整结果（最优置顶）。"""
    if options.anchors:
        return _generate_anchor(planner, start, options)
    t_all = time.time()
    candidates: List[Candidate] = []
    stage_times: dict = {}
    ok_count = 0
    http_start = getattr(planner, "http_calls", 0)
    n_points = options.n_points or adaptive_n_points(options.target_m)

    for seed in options.seeds:
        # 阶段 N：只有「距离达标」的候选才计入 max_candidates。首个 seed 虽能
        # 生成但超出 ±tol 时继续试后续 seed（App 默认发 [1,2,3]），避免把
        # 超差路线当成第一条成功路线直接返回（50km 实测 seed1 +1387m、
        # seed3 −281m）。达标立即停，成本不变。
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
            fix_detours=options.fix_detours,
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
                metrics = analyze_route(all_steps, cr.loop.polyline, options.target_m,
                                        segments=cr.loop.segments)
            candidates.append(Candidate(
                seed=seed, loop=cr.loop,
                score=score_route(options.target_m, cr.loop, metrics),
                api_calls=cr.api_calls, elapsed_s=dt, history=cr.history,
                metrics=metrics))
            if abs(cr.loop.distance_m - options.target_m) <= options.tol_m:
                ok_count += 1

    total_http = getattr(planner, "http_calls", 0) - http_start
    ranked = rank_candidates(candidates, options.target_m, options.tol_m)
    # max_candidates 只截断「成功生成的候选」；失败候选保留用于如实报错。
    ok_part = [c for c in ranked if c.error is None and c.loop is not None]
    bad_part = [c for c in ranked if c not in ok_part]
    ranked = ok_part[:max(1, options.max_candidates)] + bad_part
    return GenerateResult(
        target_m=options.target_m, start=start,
        candidates=ranked,
        total_api_calls=total_http, total_elapsed_s=round(time.time() - t_all, 2),
        stage_times=stage_times)
