#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 K 回归基准：蔡甸固定坐标真实 API，对齐阶段 J 场景表并新增绕行优化字段。

场景：
  A) 单候选 seed=2，5/10/15/20km —— 对齐阶段 I/J 报告表；
  B) App 默认首条 seeds=[1,2,3] max1，15km —— 绕行修复开启（交付态）；
  B0) 同 B 但 fix_detours=False —— 绕行优化前后对比（用户规范 10.2）；
  C) 三候选 seeds=[1,2,3] max3，15km。

每行记录：dist/err/within/closure/score/turns/dens/sharp/uturn/straight_max/
rep/无效绕行修复数(spur_fixes)/重校(spur_recal)/残留绕行区间(remaining_spurs)/
构建失败(build_fails)/调用/耗时。

用法：python backend/bench_phase_k.py [--quick]
结果写 backend/out/bench_phase_k.json。
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner, GenerateOptions, find_spur_intervals, generate_candidates,
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
    hist = rec.history or []
    ev = [h.get("event") for h in hist if "event" in h]
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
        "spur_fixes": ev.count("spur_fix"),
        "spur_recal": any(e in ("spur_recal", "spur_recal_accept") for e in ev),
        "spur_saved_m": round(sum(h.get("saved_m", 0) for h in hist
                                  if h.get("event") == "spur_fix"), 1),
        "remaining_spurs": len(find_spur_intervals(rec.loop.polyline)),
        "build_fails": sum(1 for h in hist if "error" in h),
        "rec_calls": rec.api_calls, "rec_wall_s": rec.elapsed_s,
    })
    return row


def run(planner, target, seeds, max_cand, scenario, seed_label, fix_detours=True):
    opts = GenerateOptions(target_m=target, seeds=seeds, tol_m=500,
                           max_iters=8, detour_factor=1.7, sleep_s=0.05,
                           max_candidates=max_cand, max_api_calls=800,
                           fix_detours=fix_detours)
    res = generate_candidates(planner, CAIDIAN, opts)
    row = summarize(res, target, scenario, seed_label)
    if row.get("ok"):
        print(f"[{scenario}] {target/1000:.0f}km seed={seed_label}: "
              f"dist={row['dist']} err={row['err']:+.0f} within={'Y' if row['within'] else 'N'} "
              f"score={row['score']} turns={row['turns']} dens={row['density']} "
              f"sharp={row['sharp']} uturn={row['uturn']} rep={row['rep']} "
              f"spur_fix={row['spur_fixes']}(-{row['spur_saved_m']}m) left={row['remaining_spurs']} "
              f"| rec {row['rec_calls']}c/{row['rec_wall_s']}s "
              f"| total {row['total_calls']}c/{row['total_wall_s']}s")
    else:
        print(f"[{scenario}] {target/1000:.0f}km seed={seed_label}: FAILED "
              f"(total {row['total_calls']}c/{row['total_wall_s']}s)")
    sys.stdout.flush()
    return row


def main():
    quick = "--quick" in sys.argv
    planner = AmapWalkingPlanner(load_key(), sleep=0.15)
    rows = []

    # A) 单候选 seed=2 —— 对齐阶段 I/J 报告表
    for target in (5000, 10000, 15000, 20000):
        rows.append(run(planner, target, [2], 1, "A_single_seed2", "2"))

    if not quick:
        # B/B0) App 默认首条 @15km：绕行修复 开/关 对比
        rows.append(run(planner, 15000, [1, 2, 3], 1, "B_app_first_15km_fix", "1,2,3"))
        rows.append(run(planner, 15000, [1, 2, 3], 1, "B0_app_first_15km_nofix",
                        "1,2,3", fix_detours=False))
        # C) 三候选 @15km
        rows.append(run(planner, 15000, [1, 2, 3], 3, "C_three_cand_15km", "1,2,3"))

    out = os.path.join(HERE, "backend", "out", "bench_phase_k.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print(f"\nSAVED {out}  (total real HTTP: {planner.http_calls})")


if __name__ == "__main__":
    main()
