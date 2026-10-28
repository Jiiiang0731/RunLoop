#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
阶段 1：约 15km 闭合环线最小验证脚本。

算法骨架（控制点 -> 步行路径规划 -> 闭环连接 -> 距离校准）：
  1. 以固定起点为中心，按目标距离估算环半径 R ≈ L/(2π)。
  2. 在半径 R 的圆上生成 M 个控制点（角度 + 随机抖动，由 seed 决定）。
  3. 相邻控制点（含"最后一点 -> 起点"闭合段）两两调用高德【步行路径规划】，
     得到每段真实道路距离与折线（以 API 返回 distance 为准，非直线距离）。
  4. 拼接折线，得到闭环；总距离 = 各段 distance 之和。
  5. 用 R 做比例缩放迭代，使总距离逼近目标（±500m，尽量 ±300m）。
  6. 输出：总距离、误差、起终点直线距离、分段信息、API 调用次数、耗时、种子变化。

坐标系约定：全程 GCJ-02（高德坐标系）。真实 GPS(WGS-84) 需先经坐标转换（已单独验证）。
"""
import argparse
import json
import math
import os
import random
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://restapi.amap.com"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY_FILE = os.path.join(HERE, "config", "amap_key.local")
# 城市道路绕行系数：最短步行路径长度 / 直线距离，实测约 1.7（用于初始 R 估算，加速收敛）
DETOUR_FACTOR = 1.7


def load_key() -> str:
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("no key in " + KEY_FILE)


def http_get_json(url: str, timeout: int = 30):
    req = urllib.request.Request(url, headers={"User-Agent": "RunLoop-phase1/0.1"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw), time.time() - t0


def haversine(a, b) -> float:
    """(lng,lat) 两点直线距离，单位米。"""
    R = 6371000.0
    lng1, lat1 = math.radians(a[0]), math.radians(a[1])
    lng2, lat2 = math.radians(b[0]), math.radians(b[1])
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def polyline_length(pts) -> float:
    return sum(haversine(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def ring_waypoints(center, R_m, M, seed):
    """在中心周围生成 M 个环形控制点（约在半径 R_m 的圆上，带抖动）。"""
    rng = random.Random(seed)
    lng, lat = center
    mlat = 110574.0
    mlng = 111320.0 * math.cos(math.radians(lat))
    base = rng.uniform(0, 2 * math.pi)
    pts = []
    for i in range(M):
        th = base + 2 * math.pi * i / M
        rr = R_m * (1 + rng.uniform(-0.15, 0.15))
        pts.append((round(lng + rr * math.cos(th) / mlng, 6),
                    round(lat + rr * math.sin(th) / mlat, 6)))
    return pts


def parse_polyline_from_steps(steps):
    pts = []
    for s in steps:
        for chunk in (s.get("polyline") or "").split(";"):
            chunk = chunk.strip()
            if not chunk:
                continue
            parts = chunk.split(",")
            if len(parts) == 2:
                try:
                    pts.append((float(parts[0]), float(parts[1])))
                except ValueError:
                    pass
    return pts


def walking_route(key, origin, dest, retries=2, sleep=0.2):
    """步行路径规划：返回 (distance_m, duration_s, points, error) 。"""
    o = f"{origin[0]:.6f},{origin[1]:.6f}"
    d = f"{dest[0]:.6f},{dest[1]:.6f}"
    q = urllib.parse.urlencode({"origin": o, "destination": d, "key": key})
    url = f"{BASE}/v3/direction/walking?{q}"
    last_err = None
    for attempt in range(retries + 1):
        try:
            data, _dt = http_get_json(url)
        except Exception as e:  # noqa: BLE001
            last_err = f"exception:{type(e).__name__}"
            if attempt < retries:
                time.sleep(sleep)
                continue
            return None, None, None, last_err
        if str(data.get("status")) == "1" and data.get("route") and data["route"].get("paths"):
            p = data["route"]["paths"][0]
            pts = parse_polyline_from_steps(p.get("steps", []))
            # 高德步行 API 的 distance/duration 为字符串，需转数值
            try:
                dist = int(float(p.get("distance") or 0))
            except (TypeError, ValueError):
                dist = 0
            try:
                dur = int(float(p.get("duration") or 0))
            except (TypeError, ValueError):
                dur = 0
            return dist, dur, pts, None
        last_err = f"infocode={data.get('infocode')} info={data.get('info')}"
        if attempt < retries:
            time.sleep(sleep)
            continue
        return None, None, None, last_err
    return None, None, None, last_err


def build_loop(key, start, waypoints, sleep=0.12):
    """依次连接 start -> wp0 -> ... -> wp[M-1] -> start，拼成闭环。"""
    seq = [start] + waypoints + [start]
    total = 0.0
    duration = 0.0
    allpts = []
    segments = []
    calls = 0
    for i in range(len(seq) - 1):
        dist, dur, pts, err = walking_route(key, seq[i], seq[i + 1])
        calls += 1
        if err:
            return None, calls, {"error": err, "from": seq[i], "to": seq[i + 1]}
        total += dist or 0
        duration += dur or 0
        if pts:
            if allpts:
                allpts.extend(pts[1:] if len(pts) > 1 else pts)  # 去重共享端点
            else:
                allpts.extend(pts)
        segments.append({"i": i, "from": seq[i], "to": seq[i + 1],
                         "distance": dist, "duration": dur, "n_points": len(pts or [])})
        time.sleep(sleep)
    closure = haversine(allpts[0], allpts[-1]) if len(allpts) >= 2 else None
    start_snap = haversine(start, allpts[0]) if allpts else None
    return {
        "distance": total,
        "duration": duration,
        "n_points": len(allpts),
        "closure_m": round(closure, 1) if closure is not None else None,
        "start_snap_m": round(start_snap, 1) if start_snap is not None else None,
        "polyline_length_m": round(polyline_length(allpts), 1),
        "polyline_pts": allpts,
        "segments": segments,
    }, calls, None


def run_candidate(key, start, target, M, seed, tol, max_iters, sleep):
    """对单个种子做 R 缩放迭代，返回最佳候选与历史。"""
    R = target / (2 * math.pi * DETOUR_FACTOR)
    best, best_err = None, None
    calls = 0
    history = []
    for it in range(max_iters):
        wps = ring_waypoints(start, R, M, seed)  # 同一 seed 保持形状，仅缩放 R
        res, c, err = build_loop(key, start, wps, sleep)
        calls += c
        if err:
            history.append({"iter": it, "R": round(R, 1), "error": err})
            R = R * random.Random(seed * 131 + it).uniform(0.9, 1.15)
            continue
        e = res["distance"] - target
        history.append({"iter": it, "R": round(R, 1), "distance": round(res["distance"], 1),
                        "err": round(e, 1), "closure_m": res["closure_m"]})
        if best is None or abs(e) < best_err:
            best, best_err = res, abs(e)
        if abs(e) <= tol:
            break
        factor = target / max(res["distance"], 1.0)
        R = R * (1 + 0.6 * (factor - 1))
    return best, best_err, calls, history


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=int, default=15000, help="目标距离(米)")
    ap.add_argument("--start", type=str, default="121.552563,31.215725", help="起点 GCJ-02 lng,lat")
    ap.add_argument("--points", type=int, default=10, help="控制点数量 M")
    ap.add_argument("--seeds", type=str, default="1,2", help="逗号分隔的随机种子")
    ap.add_argument("--max-iters", type=int, default=8)
    ap.add_argument("--tol", type=int, default=500)
    ap.add_argument("--sleep", type=float, default=0.12)
    ap.add_argument("--out", type=str, default=os.path.join(HERE, "backend", "out", "loop_result.json"))
    args = ap.parse_args()

    key = load_key()
    lng, lat = (float(x) for x in args.start.split(","))
    start = (lng, lat)
    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    tol = args.tol

    t_all = time.time()
    results = []
    for seed in seeds:
        t0 = time.time()
        best, best_err, calls, history = run_candidate(
            key, start, args.target, args.points, seed, tol, args.max_iters, args.sleep)
        dt = time.time() - t0
        if best:
            results.append({
                "seed": seed,
                "distance": round(best["distance"], 1),
                "error": round(best["distance"] - args.target, 1),
                "closure_m": best["closure_m"],
                "start_snap_m": best["start_snap_m"],
                "n_points": best["n_points"],
                "polyline_length_m": best["polyline_length_m"],
                "segments_summary": {
                    "count": len(best["segments"]),
                    "avg_m": round(best["distance"] / len(best["segments"]), 1),
                    "min_m": min(s["distance"] for s in best["segments"]),
                    "max_m": max(s["distance"] for s in best["segments"]),
                },
                "api_calls": calls,
                "elapsed_s": round(dt, 1),
                "history": history,
                "polyline_sample": best["polyline_pts"][::max(1, len(best["polyline_pts"]) // 200)],
            })
        else:
            results.append({"seed": seed, "error": "FAILED", "api_calls": calls,
                            "elapsed_s": round(dt, 1), "history": history})
        print(f"seed={seed}  done  calls={calls}  time={dt:.1f}s  " +
              (f"dist={best['distance']:.0f}m err={best['distance']-args.target:+.0f}m close={best['closure_m']}m"
               if best else "FAILED"))

    total_calls = sum(r.get("api_calls", 0) for r in results)
    out = {
        "target_m": args.target,
        "start_gcj02": args.start,
        "M": args.points,
        "tol_m": tol,
        "total_api_calls": total_calls,
        "total_elapsed_s": round(time.time() - t_all, 1),
        "candidates": results,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"TOTAL calls={total_calls} elapsed={time.time()-t_all:.1f}s -> {args.out}")


if __name__ == "__main__":
    main()
