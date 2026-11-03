#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 K 骨架探索（决策#4）：fig8/petal 与阶段 J 冠军骨架的真实 API 实测对比。

方法：相同固定坐标（蔡甸）、相同目标距离、相同搜索预算（max_calls=50/次校准）、
相同容差（±500m 硬约束），逐变体单独运行 calibrate（含 spur_fix 修复链），
记录误差/闭合/转弯/密度/急弯/掉头/最长直线/重复率/残留绕行/调用/耗时/构建失败。

变体：
  - lean_ell：plan_variants 首位（阶段 J 现役冠军，10km n=5 / 15km n=6）；
  - fig8_n8 ：Gerono 双纽线 8 字（两个 ~target/2 的环，交叉点即起点附近）；
  - petal_n9：四瓣玫瑰线（4 个 ~target/4 的小环）。

用法：python backend/bench_phase_k_explore.py [--smoke]
结果写 backend/out/bench_phase_k_explore.json。
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner, SkeletonVariant, adaptive_n_points, calibrate,
    find_spur_intervals, plan_variants,
)

KEY_FILE = os.path.join(HERE, "config", "amap_key.local")
CAIDIAN = (114.087279, 30.536395)
# 相同预算对所有变体公平：fig8/petal 每次构建 9~10 条腿，50 次只够 ~5 轮
# R 迭代（smoke 实测被预算截断在容差外），80 次允许 ~8 轮，与 lean 变体
# max_iters=6 的收敛需求对齐。
MAX_CALLS = 80


def load_key():
    with open(KEY_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("no key")


def explore_variants(target, n_points, seed):
    champion = plan_variants(target, n_points, seed)[0]  # lean_ell 或 base
    a = float((seed * 47) % 180)
    return [
        champion,
        SkeletonVariant(n_points=8, aspect=1.0, angle_deg=a, jitter=0.10,
                        max_iters=6, label="fig8_n8", shape="fig8"),
        SkeletonVariant(n_points=9, aspect=1.0, angle_deg=a, jitter=0.10,
                        max_iters=6, label="petal_n9", shape="petal"),
    ]


def run_one(planner, target, seed, v):
    t0 = time.time()
    cr = calibrate(planner, CAIDIAN, target, v.n_points, seed, tol_m=500,
                   max_iters=8, sleep=0.05, variants=[v],
                   max_calls=MAX_CALLS, fix_detours=True)
    wall = round(time.time() - t0, 1)
    row = {"target": target, "seed": seed, "variant": v.label,
           "shape": v.shape, "n_points": v.n_points,
           "calls": cr.api_calls, "wall_s": wall}
    iters = [h for h in cr.history if "iter" in h]
    row["build_fails"] = sum(1 for h in iters if "error" in h)
    row["iters_used"] = sum(1 for h in iters if "error" not in h)
    ev = [h.get("event") for h in cr.history if "event" in h]
    row["spur_fixes"] = ev.count("spur_fix")
    row["spur_recal"] = any(e in ("spur_recal", "spur_recal_accept") for e in ev)

    if cr.loop is None or cr.loop.error:
        row["ok"] = False
        print(f"  {v.label:10s} seed{seed} {target//1000}km: FAILED "
              f"({cr.api_calls}calls/{wall}s fails={row['build_fails']})")
        sys.stdout.flush()
        return row

    err = cr.loop.distance_m - target
    m = cr.best_metrics or {}
    row.update({
        "ok": True,
        "dist": round(cr.loop.distance_m, 1), "err": round(err, 1),
        "within": abs(err) <= 500, "closure": cr.loop.closure_m,
        "score": cr.best_score,
        "turns": m.get("turns"), "density": m.get("turn_density"),
        "sharp": m.get("sharp_turns"), "uturn": m.get("uturns"),
        "straight_max": m.get("straight_max_m"), "rep": m.get("repetition_ratio"),
        "remaining_spurs": len(find_spur_intervals(cr.loop.polyline)),
    })
    print(f"  {v.label:10s} seed{seed} {target//1000}km: err={row['err']:+7.1f} "
          f"within={'Y' if row['within'] else 'N'} score={row['score']:5.1f} "
          f"turns={row['turns']:>2} dens={row['density']} sharp={row['sharp']} "
          f"uturn={row['uturn']} rep={row['rep']} spur_fix={row['spur_fixes']} "
          f"left={row['remaining_spurs']} | {cr.api_calls}calls/{wall}s")
    sys.stdout.flush()
    return row


def main():
    smoke = "--smoke" in sys.argv
    planner = AmapWalkingPlanner(load_key(), sleep=0.15)
    rows = []

    if smoke:
        n = adaptive_n_points(15000)
        v = explore_variants(15000, n, 1)[1]  # fig8_n8
        print("[smoke] fig8_n8 seed1 15km（验证真实 API 全链路）")
        rows.append(run_one(planner, 15000, 1, v))
    else:
        for target in (10000, 15000):
            n = adaptive_n_points(target)
            for seed in (1, 2):
                print(f"[explore] target={target//1000}km seed={seed}")
                for v in explore_variants(target, n, seed):
                    rows.append(run_one(planner, target, seed, v))

    out = os.path.join(HERE, "backend", "out",
                       "bench_phase_k_smoke.json" if smoke else "bench_phase_k_explore.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print(f"\nSAVED {out}  (total real HTTP: {planner.http_calls})")


if __name__ == "__main__":
    main()
