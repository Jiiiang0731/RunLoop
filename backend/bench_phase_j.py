#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 J 基准测试：用真实高德 API（蔡甸固定坐标）跑真实的 generate_candidates 路径，
对比阶段 I 的转弯密度/评分/耗时/调用数。

场景：
  A) 单候选 seed=2，5/10/15/20km —— 直接对齐阶段 I 报告表格；
  B) App 默认单候选 seeds=[1,2,3] max_candidates=1，15km —— 真实首条体验；
  C) 三候选 seeds=[1,2,3] max_candidates=3，15km —— 对齐阶段 I 三候选。

用法：python backend/bench_phase_j.py [--quick]
结果写 backend/out/bench_phase_j.json。
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner, GenerateOptions, generate_candidates,
)

KEY_FILE = os.path.join(HERE, "config", "amap_key.local")
CAIDIAN = (114.087279, 30.536395)


def load_key():
    with open(KEY_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("no key")


def summarize(res, target, scenario, seed_label):
    rec = next((c for c in res.candidates if c.recommended), None)
    rec = rec or next((c for c in res.candidates if c.error is None), None)
    row = {"scenario": scenario, "target": target, "seed": seed_label,
           "total_calls": res.total_api_calls, "total_wall_s": res.total_elapsed_s,
           "n_ok": sum(1 for c in res.candidates if c.error is None)}
    if rec is None or rec.loop is None:
        row["ok"] = False
        return row
    m = rec.metrics or {}
    err = rec.loop.distance_m - target
    row.update({
        "ok": True, "rec_seed": rec.seed,
        "dist": round(rec.loop.distance_m, 1), "err": round(err, 1),
        "within": abs(err) <= 500, "closure": rec.loop.closure_m,
        "score": rec.score.total if rec.score else None,
        "turns": m.get("turns"), "density": m.get("turn_density"),
        "sharp": m.get("sharp_turns"), "uturn": m.get("uturns"),
        "short": m.get("short_consecutive"),
        "straight_max": m.get("straight_max_m"),
        "ratio300": m.get("straight_ratio_300"),
        "rep": m.get("repetition_ratio"),
        "rec_calls": rec.api_calls, "rec_wall_s": rec.elapsed_s,
    })
    return row


def run(planner, target, seeds, max_cand, scenario, seed_label):
    opts = GenerateOptions(target_m=target, seeds=seeds, tol_m=500,
                           max_iters=8, detour_factor=1.7, sleep_s=0.05,
                           max_candidates=max_cand, max_api_calls=600)
    res = generate_candidates(planner, CAIDIAN, opts)
    row = summarize(res, target, scenario, seed_label)
    if row.get("ok"):
        print(f"[{scenario}] {target/1000:.0f}km seed={seed_label}: "
              f"dist={row['dist']} err={row['err']:+.0f} within={'Y' if row['within'] else 'N'} "
              f"score={row['score']} turns={row['turns']} density={row['density']} "
              f"sharp={row['sharp']} uturn={row['uturn']} rep={row['rep']} "
              f"| rec {row['rec_calls']}calls/{row['rec_wall_s']}s "
              f"| total {row['total_calls']}calls/{row['total_wall_s']}s")
    else:
        print(f"[{scenario}] {target/1000:.0f}km seed={seed_label}: FAILED "
              f"(total {row['total_calls']}calls/{row['total_wall_s']}s)")
    sys.stdout.flush()
    return row


def main():
    quick = "--quick" in sys.argv
    planner = AmapWalkingPlanner(load_key(), sleep=0.15)
    rows = []
    only_c = "--three-only" in sys.argv

    if only_c:
        # 独立、无缓存复用地测三候选（对齐阶段 I 三候选场景）
        rows.append(run(planner, 15000, [1, 2, 3], 3, "C_three_cand_15km", "1,2,3"))
    else:
        # A) 单候选 seed=2 —— 对齐阶段 I 报告表
        for target in (5000, 10000, 15000, 20000):
            rows.append(run(planner, target, [2], 1, "A_single_seed2", "2"))

        if not quick:
            # B) App 默认首条 seeds=[1,2,3] max1 @15km
            rows.append(run(planner, 15000, [1, 2, 3], 1, "B_app_first_15km", "1,2,3"))
            # C) 三候选 @15km
            rows.append(run(planner, 15000, [1, 2, 3], 3, "C_three_cand_15km", "1,2,3"))

    out = os.path.join(HERE, "backend", "out",
                       "bench_phase_j_three.json" if only_c else "bench_phase_j.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print(f"\nSAVED {out}  (total real HTTP: {planner.http_calls})")


if __name__ == "__main__":
    main()
