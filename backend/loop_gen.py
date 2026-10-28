#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成闭合跑步环线（CLI）。示例：
    python backend/loop_gen.py --target 15000 --seeds 1,2,3
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)  # 使 backend 包可导入

from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner, GenerateOptions, generate_candidates,
)

KEY_FILE = os.path.join(HERE, "config", "amap_key.local")


def load_key() -> str:
    with open(KEY_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("no key in " + KEY_FILE)


def serialize(res):
    return {
        "target_m": res.target_m,
        "start_gcj02": f"{res.start[0]:.6f},{res.start[1]:.6f}",
        "total_api_calls": res.total_api_calls,
        "total_elapsed_s": res.total_elapsed_s,
        "candidates": [
            {
                "seed": c.seed,
                "error": c.error,
                **({} if c.loop is None else {
                    "distance": round(c.loop.distance_m, 1),
                    "error_m": round(c.loop.distance_m - res.target_m, 1),
                    "closure_m": c.loop.closure_m,
                    "start_snap_m": c.loop.start_snap_m,
                    "n_points": len(c.loop.polyline),
                    "segments": len(c.loop.segments),
                }),
                **({} if c.score is None else {
                    "score": c.score.total,
                    "score_components": [
                        {"name": s.name, "score": s.score, "available": s.available, "detail": s.detail}
                        for s in c.score.components
                    ],
                }),
                "api_calls": c.api_calls,
                "elapsed_s": c.elapsed_s,
                "history": c.history,
            }
            for c in res.candidates
        ],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=int, default=15000)
    ap.add_argument("--start", type=str, default="121.552563,31.215725")
    ap.add_argument("--points", type=int, default=10)
    ap.add_argument("--seeds", type=str, default="1,2,3")
    ap.add_argument("--max-iters", type=int, default=8)
    ap.add_argument("--tol", type=int, default=500)
    ap.add_argument("--detour", type=float, default=1.7)
    ap.add_argument("--sleep", type=float, default=0.02)
    ap.add_argument("--out", type=str, default=os.path.join(HERE, "backend", "out", "loop_result.json"))
    args = ap.parse_args()

    key = load_key()
    lng, lat = (float(x) for x in args.start.split(","))
    opts = GenerateOptions(
        target_m=args.target, n_points=args.points,
        seeds=[int(s) for s in args.seeds.split(",") if s.strip()],
        tol_m=args.tol, max_iters=args.max_iters,
        detour_factor=args.detour, sleep_s=args.sleep,
    )
    res = generate_candidates(AmapWalkingPlanner(key), (lng, lat), opts)

    for c in res.candidates:
        if c.loop is not None and c.loop.ok and c.score is not None:
            print(f"seed={c.seed}  dist={c.loop.distance_m:.0f}m  err={c.loop.distance_m - args.target:+.0f}m  "
                  f"close={c.loop.closure_m}m  score={c.score.total}  calls={c.api_calls}  {c.elapsed_s}s")
        else:
            print(f"seed={c.seed}  FAILED  {c.error}  calls={c.api_calls}")
    print(f"TOTAL calls={res.total_api_calls} elapsed={res.total_elapsed_s}s -> {args.out}")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(serialize(res), f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
