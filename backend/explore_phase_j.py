#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 J 探索脚本：蔡甸区固定坐标下对比不同骨架配置的「转弯质量 vs API 成本」。

用法：
    python backend/explore_phase_j.py --target 15000 --seeds 2
    python backend/explore_phase_j.py --target 15000 --seeds 1,2,3 --configs base_n9,ell15_n7

结果打印为表格并写入 backend/out/explore_j_<target>_<seeds>.json。
共享同一个 AmapWalkingPlanner（跨配置命中分段缓存，节省真实配额）；
http_delta 为该配置消耗的真实 HTTP 次数，ops 为分段规划操作数（含缓存命中）。
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner, SkeletonVariant, calibrate,
)

KEY_FILE = os.path.join(HERE, "config", "amap_key.local")
CAIDIAN = (114.087279, 30.536395)  # GCJ-02，与阶段 D/I 相同的固定测试坐标

# 配置名 -> (n_points, aspect, jitter, max_iters, angle_fn)
CONFIGS = {
    # 旧基线（阶段 I 自适应：15km→9 点圆环）
    "base_n9":   (9, 1.0, 0.15, 6, lambda s: 0.0),
    "base_n8":   (8, 1.0, 0.15, 6, lambda s: 0.0),
    "base_n6":   (6, 1.0, 0.15, 6, lambda s: 0.0),
    "base_n5":   (5, 1.0, 0.15, 6, lambda s: 0.0),
    "base_n10":  (10, 1.0, 0.15, 6, lambda s: 0.0),
    # 低抖动圆环（形状更规整，减少碎转弯）
    "cir_n6_lj": (6, 1.0, 0.06, 6, lambda s: 0.0),
    "cir_n7_lj": (7, 1.0, 0.06, 6, lambda s: 0.0),
    # 椭圆骨架（两条长直边；点数更少）
    "ell13_n6":  (6, 1.3, 0.10, 6, lambda s: float((s * 47 + 40) % 180)),
    "ell15_n4":  (4, 1.5, 0.10, 6, lambda s: float((s * 47) % 180)),
    "ell15_n5":  (5, 1.5, 0.10, 6, lambda s: float((s * 47) % 180)),
    "ell15_n6":  (6, 1.5, 0.10, 6, lambda s: float((s * 47) % 180)),
    "ell15_n7":  (7, 1.5, 0.10, 6, lambda s: float((s * 47) % 180)),
    "ell17_n4":  (4, 1.7, 0.09, 6, lambda s: float((s * 47 + 30) % 180)),
    "ell17_n6":  (6, 1.7, 0.09, 6, lambda s: float((s * 47 + 30) % 180)),
    "ell19_n6":  (6, 1.9, 0.08, 6, lambda s: float((s * 47 + 75) % 180)),
    "ell19_n7":  (7, 1.9, 0.08, 6, lambda s: float((s * 47 + 75) % 180)),
    "ell22_n5":  (5, 2.2, 0.08, 6, lambda s: float((s * 47 + 75) % 180)),
}


def load_key() -> str:
    with open(KEY_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("no key")


def run(planner, target, seed, cfg_name, tol=500, detour=1.7, sleep=0.05):
    n, aspect, jitter, iters, angle_fn = CONFIGS[cfg_name]
    v = SkeletonVariant(n_points=n, aspect=aspect, angle_deg=angle_fn(seed),
                        jitter=jitter, max_iters=iters, label=cfg_name)
    http0 = planner.http_calls
    t0 = time.time()
    cr = calibrate(planner, CAIDIAN, target, n, seed, tol_m=tol,
                   max_iters=iters, detour_factor=detour, sleep=sleep,
                   jitter=jitter, variants=[v])
    wall = round(time.time() - t0, 1)
    http_delta = planner.http_calls - http0
    row = {
        "target": target, "seed": seed, "config": cfg_name,
        "n_points": n, "aspect": aspect, "angle": v.angle_deg,
        "jitter": jitter, "wall_s": wall, "ops": cr.api_calls,
        "http": http_delta,
    }
    if cr.loop is None or cr.loop.error:
        row.update(ok=False, error=(cr.loop.error if cr.loop else "no loop"))
    else:
        m = cr.best_metrics or {}
        err = cr.loop.distance_m - target
        row.update(
            ok=True, dist=round(cr.loop.distance_m, 1), err=round(err, 1),
            within=abs(err) <= tol, closure=cr.loop.closure_m,
            score=cr.best_score, turns=m.get("turns"),
            density=m.get("turn_density"), sharp=m.get("sharp_turns"),
            uturns=m.get("uturns"), short=m.get("short_consecutive"),
            straight_max=m.get("straight_max_m"),
            ratio300=m.get("straight_ratio_300"),
            rep=m.get("repetition_ratio"),
            builds=len([h for h in cr.history if "distance" in h]),
        )
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=int, default=15000)
    ap.add_argument("--seeds", type=str, default="2")
    ap.add_argument("--configs", type=str, default=",".join(CONFIGS.keys()))
    ap.add_argument("--tol", type=int, default=500)
    ap.add_argument("--out", type=str, default="")
    args = ap.parse_args()

    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    cfgs = [c.strip() for c in args.configs.split(",") if c.strip()]
    key = load_key()
    planner = AmapWalkingPlanner(key, sleep=0.15)

    rows = []
    for seed in seeds:
        for cfg in cfgs:
            row = run(planner, args.target, seed, cfg, tol=args.tol)
            rows.append(row)
            if row.get("ok"):
                print(f"seed={seed} {cfg:10s} wall={row['wall_s']:5.1f}s ops={row['ops']:3d} "
                      f"http={row['http']:3d} dist={row['dist']:8.1f} err={row['err']:+6.1f} "
                      f"within={'Y' if row['within'] else 'N'} score={row['score']:5.1f} "
                      f"turns={row['turns']:3d} density={row['density']:4.2f} "
                      f"sharp={row['sharp']} uturn={row['uturns']} short={row['short']} "
                      f"straight_max={row['straight_max']:6.0f} rep={row['rep']:.2f}")
            else:
                print(f"seed={seed} {cfg:10s} FAILED http={row['http']} {row.get('error','')[:80]}")
            sys.stdout.flush()

    out = args.out or os.path.join(
        HERE, "backend", "out",
        f"explore_j_{args.target}_{'-'.join(map(str, seeds))}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    total_http = sum(r.get("http", 0) for r in rows)
    print(f"\nSAVED {out}  (total real HTTP calls: {total_http})")


if __name__ == "__main__":
    main()
