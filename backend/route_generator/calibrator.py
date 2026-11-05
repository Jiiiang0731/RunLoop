#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""距离校准 + 质量选择（阶段 J 重写）。

对每个骨架变体（variants.plan_variants）：
1. R 缩放迭代，使闭环道路距离逼近目标（同阶段 D 逻辑）；
2. 每个成功的闭环立即用 nav_metrics 计算真实转弯/直行/重复指标并评分（零额外 API）；
3. 全局保留「达标(±tol)候选中评分最高」的闭环；若全部不达标，保留误差最小者；
4. 提前终止：某闭环既达标、质量又足够好（评分高或转弯密度低且无掉头/急弯少）时，
   不再尝试后续变体，控制 API 调用与耗时。

兼容性：单变体调用（variants=[SkeletonVariant(...)]）与旧行为一致；
默认（variants=None）按 seed/目标距离自动展开 3 个变体。
"""
import math
import random
from typing import List, Optional

from .control_points import generate_ring
from .geo import GeoPoint
from .loop_builder import build_loop
from .nav_metrics import analyze_route
from .planner import MapPlanner
from .scorer import score_route
from .spur_fix import MAX_FIXES, fix_spurs
from .types import CalibrateResult, LoopRoute
from .variants import SkeletonVariant, plan_variants

# 提前终止阈值（蔡甸真实 API 探索标定，见 docs/phase_j_report.md）：
# 达标且（评分 ≥ EARLY_MIN_SCORE 或 转弯密度 ≤ EARLY_MAX_DENSITY 且无掉头且急弯 ≤1）。
# 阶段 K 决策#2（质量优先）：50 → 55。实测评分分布 39.9~69.3，阈值 50 会让
# 51.0/50.3 这类「尚可但未必最优」的首变体提前收工；提到 55 后这类路线会再试
# base 变体择优（变体级止损仍限制最多 3 变体），用少量调用换更高质量上限。
EARLY_MIN_SCORE = 55.0
EARLY_MAX_DENSITY = 1.5

# 单变体连续规划失败（路网不可达等）达到该次数则放弃该变体
_MAX_BUILD_FAILS_PER_VARIANT = 2

# 阶段 N：不适合跑步的路段（地下通道/过街天桥/扶梯/台阶等，来自 walk_type）
# 占里程超过该比例时，该闭环不参与「最优」选择（仅在无其他候选时兜底）。
MAX_WALK_BAD_RATIO = 0.15


def tight_tolerance(tol_m: float, target_m: int) -> float:
    """内部「够好了」阈值（阶段 N）。

    用户规范：±500m 是**最大容差**，不是合格线。内部目标 = 5% 目标距离，
    下限 30m，且不超过硬容差（长距离仍受 ±500m 约束，保持 J/K 质量）。
    1km→50m，2.5km→125m，5km→250m，50km→500m。
    """
    return min(float(tol_m), max(30.0, 0.05 * float(target_m)))


def _ring_base_angle(v) -> Optional[float]:
    """偏移中心变体：把第一个控制点放到起点所在的环边缘（P1）。

    默认圆心=起点时，闭环实际是「起点→圆周→回到起点」的棒棒糖：两条径向
    腿常常原路折返，产生无意义 20~50m 折返与多余掉头。center 偏移 R 且
    第一个点正对起点时，起点就在环线上，闭环真正绕一圈。
    矩形骨架参数从角点起算，不做该对齐。
    """
    if v.offset_factor > 0 and getattr(v, "shape", "ring") != "rect":
        # generate_ring 的极角以正东为 0、逆时针；variant_center 的
        # offset_dir_deg 以正北为 0、顺时针。中心在起点 dir 方向、半径 R，
        # 起点相对中心的罗盘方向是 dir+180，对应数学极角 270-dir；
        # 再减去骨架整体旋转 angle_deg。
        return (270.0 - v.offset_dir_deg - v.angle_deg) % 360.0
    return None


def variant_center(start, v, radius_m: float):
    """骨架中心：起点，或按变体的偏移方位/倍率外移（阶段 N）。

    自然环线常常不以起点为圆心（实测校园环线中心比起点偏移 ~450m），
    同心圆骨架因此永远找不到它；偏移中心让搜索能覆盖「起点在环线一角」
    的形态。
    """
    if v.offset_factor <= 0 or v.offset_dir_deg < 0:
        return start
    off = v.offset_factor * radius_m
    brg = math.radians(v.offset_dir_deg)
    d_north = math.cos(brg) * off
    d_east = math.sin(brg) * off
    lat = start[1] + d_north / 110574.0
    lng = start[0] + d_east / (111320.0 * math.cos(math.radians(start[1])))
    return (lng, lat)


def _loop_metrics(loop: LoopRoute, target_m: int) -> dict:
    all_steps = []
    for seg in loop.segments:
        all_steps.extend(seg.steps)
    return analyze_route(all_steps, loop.polyline, target_m,
                         segments=loop.segments)


def _is_better(err: float, score: Optional[float], best_err: Optional[float],
               best_score: Optional[float], tol_m: int) -> bool:
    """候选比较：达标者优先；同为达标比评分；同为不达标比误差绝对值。"""
    if best_err is None:
        return True
    ok, best_ok = abs(err) <= tol_m, abs(best_err) <= tol_m
    if ok and not best_ok:
        return True
    if best_ok and not ok:
        return False
    if ok and best_ok:
        return (score or 0.0) > (best_score or 0.0)
    return abs(err) < abs(best_err)


def _should_stop_early(err: float, score: float, metrics: dict, tol_m: int) -> bool:
    if abs(err) > tol_m:
        return False
    if score >= EARLY_MIN_SCORE:
        return True
    return (float(metrics.get("turn_density", 9.9)) <= EARLY_MAX_DENSITY
            and int(metrics.get("uturns", 9)) == 0
            and int(metrics.get("sharp_turns", 9)) <= 1)


def _append_fix_events(history: list, sres, tag: str = "spur") -> None:
    """把一轮 fix_spurs 的结果写入校准历史（修复明细 + 拒绝原因汇总）。"""
    for f in sres.fixes:
        history.append({"event": f"{tag}_fix", "saved_m": f.saved_m,
                        "span_m": f.span_m, "repl_m": f.repl_m,
                        "old_turns": f.old_turns, "new_turns": f.new_turns})
    rejects: dict = {}
    for a in sres.attempts:
        reason = str(a.get("reject", "?")).split(":")[0]
        rejects[reason] = rejects.get(reason, 0) + 1
    if rejects:
        history.append({"event": f"{tag}_reject", "reasons": rejects})


def calibrate(planner: MapPlanner, start: GeoPoint, target_m: int, n_points: int,
              seed: int, tol_m: int = 500, max_iters: int = 8,
              detour_factor: float = 1.7, sleep: float = 0.0,
              jitter: float = 0.15,
              variants: Optional[List[SkeletonVariant]] = None,
              max_calls: Optional[int] = None,
              fix_detours: bool = True) -> CalibrateResult:
    """多骨架变体校准，返回达标候选中评分最高（或误差最小）的闭环。

    - max_calls：本次校准的 HTTP 调用硬预算（None=不限）；
    - variants：显式骨架变体列表（默认 plan_variants 生成，base 变体使用入参 jitter）；
    - fix_detours：阶段 K——对达标最优闭环做无效绕行替换（spur_fix），
      修复后复检 ±tol：仍达标则采用；被修短超差则按修复后距离重校 R 重建一次；
      仍不行回退原路线（距离硬约束优先于绕行消除，用户规范 3.3/第五部分）。
    """
    if variants is None:
        variants = plan_variants(target_m, n_points, seed,
                                 base_jitter=jitter, base_max_iters=max_iters)

    tight = tight_tolerance(tol_m, target_m)
    best: Optional[LoopRoute] = None
    best_err: Optional[float] = None
    best_score: Optional[float] = None
    best_metrics: Optional[dict] = None
    best_variant: Optional[SkeletonVariant] = None
    best_R: float = 0.0
    calls = 0
    history: List[dict] = []
    stopped_early = False
    variants_tried = 0

    for v in variants:
        if stopped_early:
            break
        if max_calls is not None and calls >= max_calls:
            break
        variants_tried += 1
        iters = min(v.max_iters, max_iters) if v.label == "base" else v.max_iters
        R = target_m / (2 * math.pi * detour_factor) * v.radius_factor
        # 阶段 N：记录本次变体内已试的 (R, 真实距离)，用于振荡防护
        samples: List[tuple] = []
        fails = 0
        for it in range(iters):
            if max_calls is not None and calls >= max_calls:
                break
            wps = generate_ring(variant_center(start, v, R), R, v.n_points, seed,
                                jitter=v.jitter, aspect=v.aspect,
                                angle_deg=v.angle_deg, shape=v.shape,
                                base_angle_deg=_ring_base_angle(v))
            loop, c = build_loop(planner, start, wps, sleep=sleep)
            calls += c
            if loop.error:
                fails += 1
                history.append({"variant": v.label, "iter": it, "R": round(R, 1),
                                "error": loop.error})
                if fails >= _MAX_BUILD_FAILS_PER_VARIANT:
                    break
                R = R * random.Random(seed * 131 + it).uniform(0.9, 1.15)
                continue
            fails = 0
            e = loop.distance_m - target_m
            samples.append((R, loop.distance_m))
            metrics = _loop_metrics(loop, target_m)
            score = score_route(target_m, loop, metrics).total
            bad_share = float(metrics.get("walk_bad_ratio", 0.0))
            too_bad = bad_share > MAX_WALK_BAD_RATIO
            history.append({
                "variant": v.label, "iter": it, "R": round(R, 1),
                "distance": round(loop.distance_m, 1), "err": round(e, 1),
                "closure_m": loop.closure_m, "score": score,
                "turns": metrics.get("turns"), "density": metrics.get("turn_density"),
                "walk_bad": bad_share,
            })
            if too_bad:
                # 大量台阶/地下通道/天桥：不参与最优选择，只在没有更好候选时兜底
                history.append({"variant": v.label, "iter": it,
                                "event": "walk_bad_reject", "walk_bad": bad_share})
            # 选择顺序：距离先进入内部目标带（5%·目标，1km≈50m），
            # 再在带内比质量。避免为了少一个接缝折返而牺牲 100m+ 精度。
            if (not too_bad or best is None) and \
                    _is_better(e, score, best_err, best_score, tight):
                best, best_err, best_score, best_metrics = loop, e, score, metrics
                best_variant, best_R = v, R
            if not too_bad and _should_stop_early(e, score, metrics, tight):
                stopped_early = True
                break
            if not too_bad and abs(e) <= tight:
                # 已进入内部目标带（5%·目标）：质量提升交给后续骨架变体。
                break
            factor = target_m / max(loop.distance_m, 1.0)
            R_next = R * (1 + 0.6 * (factor - 1))
            # 振荡防护（阶段 N）：距离对半径高度不连续时，定点迭代会在两个
            # R 之间无限来回（实测 2.5km：R=234→4652m、R=169→1524m，重复 4 轮）。
            # 若新 R 落在已试 R 的 2% 内（或样本按 R 排序后误差变号），改用二分。
            if any(abs(R_next - r) / max(r, 1e-6) < 0.02 for r, _ in samples):
                below = [r for r, d in samples if d < target_m]
                above = [r for r, d in samples if d > target_m]
                if below and above:
                    R_next = (max(below) + min(above)) / 2.0
                elif above:
                    R_next = min(above) * 1.15
                elif below:
                    R_next = max(below) * 0.85
            R = R_next

        # 变体级止损：已尝试 ≥2 个变体且已有路线进入内部目标带 → 接受，
        # 不再试第 3 个（第 3 变体只作「前两个都不达标」时的收敛救援）。
        if (not stopped_early and best_err is not None
                and abs(best_err) <= tight and variants_tried >= 2):
            stopped_early = True

    # ---- 阶段 K：无效绕行替换（只对达标最优路线做，硬约束 ±tol 不变） ----
    # 三级策略（决策#1 绝对容差优先，决策#2 质量优先）：
    #   1) 激进修复：接受所有通过结构守卫的修复；修完仍达标 → 直接采用；
    #   2) 修出容差 → 割线法重校重建（≤3 次，预算门控）：第 1 次比例法
    #      R×(target+总节省)/原距离（把被摘掉的绕行里程加回去），之后
    #      用最近两组 (R, 修复后距离) 实测样本割线插值——距离对 R 高度
    #      非线性（跨屏障路网突变），单次线性重校实测常失败；蔡甸实测
    #      割线序列 15km: err −3132→+5533→−955→(预测≈达标)，第 3 次收敛；
    #   3) 重校全部失败 → 容差感知模式重跑（plan 命中缓存近零成本），
    #      只采用「修复后仍达标」的小绕行，否则回退原路线（硬约束赢）。
    # 1.5km 以内不做激进绕行替换：实测会把 1km 路线从 1076m 修到
    # 742m（-258m）却仍在 ±500m 内被接受，直接破坏用户要求的 0.99km 精度。
    # 1.5km 以上保留 spur_fix，但 partial accept 已加 tight 距离守卫。
    # 折返治理优先由 join 指标参与评分/选路，不再事后切割真实折线。
    if (fix_detours and target_m > 1500
            and best is not None and best_err is not None
            and abs(best_err) <= tol_m
            and (max_calls is None or calls < max_calls)):
        pre_dist = best.distance_m
        sres = fix_spurs(best, planner, sleep=sleep)
        calls += sres.calls
        _append_fix_events(history, sres)
        if sres.fixes:
            fixed = sres.loop
            e = fixed.distance_m - target_m
            if abs(e) <= tight:
                metrics_f = _loop_metrics(fixed, target_m)
                score_f = score_route(target_m, fixed, metrics_f).total
                history.append({"event": "spur_accept", "err": round(e, 1),
                                "score": score_f, "turns": metrics_f.get("turns")})
                best, best_err, best_score, best_metrics = fixed, e, score_f, metrics_f
            else:
                adopted = False
                if best_variant is not None:
                    history.append({"event": "spur_recal", "err_after_fix": round(e, 1)})
                    saved_total = max(pre_dist - fixed.distance_m, 0.0)
                    samples = [(best_R, fixed.distance_m)]
                    R_next = best_R * (target_m + saved_total) / max(pre_dist, 1.0)
                    need = best_variant.n_points + 12  # 重建腿数 + 修复/尝试余量
                    for attempt in (1, 2, 3):
                        if max_calls is not None and calls + need > max_calls:
                            history.append({"event": "spur_recal_budget",
                                            "attempt": attempt})
                            break
                        if not (0.6 * best_R <= R_next <= 1.8 * best_R):
                            history.append({"event": "spur_recal_abort",
                                            "R_mult": round(R_next / best_R, 3)})
                            break
                        wps = generate_ring(
                            variant_center(start, best_variant, R_next),
                            R_next, best_variant.n_points, seed,
                            jitter=best_variant.jitter,
                            aspect=best_variant.aspect,
                            angle_deg=best_variant.angle_deg,
                            shape=best_variant.shape,
                            base_angle_deg=_ring_base_angle(best_variant))
                        loop2, c2 = build_loop(planner, start, wps, sleep=sleep)
                        calls += c2
                        if loop2.error:
                            history.append({"event": "spur_recal_reject",
                                            "reason": "build_error",
                                            "attempt": attempt, "error": loop2.error})
                            break
                        sres2 = fix_spurs(loop2, planner, sleep=sleep)
                        calls += sres2.calls
                        _append_fix_events(history, sres2, tag="recal")
                        d2 = sres2.loop.distance_m
                        samples.append((R_next, d2))
                        e2 = d2 - target_m
                        if abs(e2) <= tight:
                            metrics2 = _loop_metrics(sres2.loop, target_m)
                            score2 = score_route(target_m, sres2.loop, metrics2).total
                            # 重建版已消除大绕行：达标且评分回落 ≤5 即采用。
                            # （评分未完全计入「垃圾绕行」的观感代价，用户目标#3
                            #  优先；决策#1 的硬约束只有 ±tol，此处已满足。）
                            if score2 >= (best_score or 0.0) - 5.0:
                                history.append({"event": "spur_recal_accept",
                                                "attempt": attempt,
                                                "err": round(e2, 1), "score": score2})
                                best, best_err = sres2.loop, e2
                                best_score, best_metrics = score2, metrics2
                                adopted = True
                            else:
                                history.append({"event": "spur_recal_reject",
                                                "reason": "score", "attempt": attempt,
                                                "score2": score2,
                                                "best_score": best_score})
                            break  # 已达标（无论是否采用）：距离反馈不再有意义
                        history.append({"event": "spur_recal_miss", "attempt": attempt,
                                        "R_mult": round(R_next / best_R, 3),
                                        "err2": round(e2, 1)})
                        (R_a, d_a), (R_b, d_b) = samples[-2], samples[-1]
                        if d_b == d_a:
                            break
                        R_next = R_a + (target_m - d_a) * (R_b - R_a) / (d_b - d_a)
                if not adopted:
                    # Stage 3：容差感知部分采用（只摘不破坏达标的小绕行）
                    sres_c = fix_spurs(best, planner, sleep=sleep,
                                       target_m=target_m, tol_m=tol_m)
                    calls += sres_c.calls
                    if sres_c.fixes:
                        metrics_c = _loop_metrics(sres_c.loop, target_m)
                        score_c = score_route(target_m, sres_c.loop, metrics_c).total
                        e_c = sres_c.loop.distance_m - target_m
                        # P1：部分采用也绝不能把距离拖出内部目标带。
                        # 实测 1km 目标曾被“修折返”修到 742m（-258m）仍被
                        # 接受——用户明确要求 1km≈0.99km，精度优先于折返。
                        if abs(e_c) <= tight and score_c >= (best_score or 0.0) - 5.0:
                            history.append({"event": "spur_partial_accept",
                                            "n_fixes": len(sres_c.fixes),
                                            "err": round(e_c, 1), "score": score_c})
                            best, best_err = sres_c.loop, e_c
                            best_score, best_metrics = score_c, metrics_c
                        else:
                            history.append({"event": "spur_revert",
                                            "reason": "partial_distance" if abs(e_c) > tight
                                                else "partial_score",
                                            "err_after_fix": round(e_c, 1),
                                            "tight_m": round(tight, 1)})
                    else:
                        history.append({"event": "spur_revert",
                                        "err_after_fix": round(e, 1)})

    return CalibrateResult(loop=best,
                           best_error_m=(abs(best_err) if best_err is not None else None),
                           api_calls=calls, history=history,
                           best_score=best_score, best_metrics=best_metrics)
