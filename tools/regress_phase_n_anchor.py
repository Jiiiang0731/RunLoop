#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：通过真实后端 HTTP API 回归 1 / 2.5 / 5 / 15 / 50km。

与单测的区别（报告必须分开写）：
- 本脚本走 `POST /api/route/generate`，验证「接入 anchor_loop 后的真实服务」，
  包括参数校验、限流/并发闸、真实高德调用、锚点裁剪、闭合与质量块序列化；
- 它会消耗真实高德配额，不能替代离线单测；
- 它只证明服务端/真实 API 行为，不证明手机端 UI、GPS、TTS 或真机网络。

用法：
    python tools/regress_phase_n_anchor.py
    RUNLOOP_BASE_URL=http://127.0.0.1:8000 python ...
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.environ.get("RUNLOOP_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
OUT = os.path.join(ROOT, "docs", "phase_n", "regression_anchor_v06.json")

# 用户提供的长江大学武汉校区 10 个锚点（有序，首点=起点）
ANCHORS = [
    [114.027494, 30.535040], [114.027651, 30.532929], [114.026649, 30.530919],
    [114.027056, 30.529165], [114.030188, 30.527506], [114.032443, 30.526696],
    [114.034197, 30.528436], [114.031535, 30.530838], [114.029966, 30.533269],
    [114.030107, 30.535383],
]

CASES = [
    # seeds 用 App 默认 [1,2,3]；阶段 N 起只有「距离达标」的候选才计入
    # max_candidates，因此前一个 seed 超差时会继续试后续 seed（50km 必需）。
    {"name": "1km_skeleton", "target_m": 1000, "seeds": [1, 2, 3]},
    {"name": "1km_skeleton_seed6", "target_m": 1000, "seeds": [6],
     "note": "阶段 N 最差复现案例（曾 586m）"},
    {"name": "2.5km_skeleton", "target_m": 2500, "seeds": [1, 2, 3],
     "note": "骨架法对照（曾 2839m / 20 转弯）"},
    {"name": "2.5km_anchor", "target_m": 2500, "seeds": [1, 2, 3],
     "anchors": ANCHORS, "verify_drivable": True},
    {"name": "5km_skeleton", "target_m": 5000, "seeds": [1, 2, 3]},
    {"name": "15km_skeleton", "target_m": 15000, "seeds": [1, 2, 3]},
    {"name": "50km_skeleton", "target_m": 50000, "seeds": [1, 2, 3]},
]


def _get(path, timeout=10):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _post(path, payload, device, timeout=360):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Device-Id": device})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except Exception:  # noqa: BLE001
            body = {"raw": raw[:500]}
        return e.code, body


def _pick_candidate(data):
    cands = data.get("candidates") or []
    for c in cands:
        if c.get("recommended"):
            return c
    for c in cands:
        if c.get("ok"):
            return c
    return cands[0] if cands else {}


def _extract(data):
    c = _pick_candidate(data)
    m = c.get("metrics") or {}
    q = c.get("quality") or {}
    mv = q.get("motor_vehicle_access") or {}
    return {
        "route_mode": data.get("route_mode"),
        "distance_m": c.get("distance_m"),
        "error_m": c.get("error_m"),
        "within_tolerance": c.get("within_tolerance"),
        "closure_m": c.get("closure_m"),
        "closure_ok": c.get("closure_ok"),
        "turns": m.get("turns"),
        "turn_density": m.get("turn_density"),
        "repetition_ratio": m.get("repetition_ratio"),
        "score": c.get("score"),
        "road_continuity_score": (q.get("road_continuity") or {}).get("score"),
        "road_safety_available": (q.get("road_safety") or {}).get("available"),
        "road_safety_score": (q.get("road_safety") or {}).get("score"),
        "traffic_available": (q.get("traffic_exposure") or {}).get("available"),
        "traffic_score": (q.get("traffic_exposure") or {}).get("score"),
        "drivable_available": mv.get("available"),
        "drivable_ratio": mv.get("driving_to_walking_ratio"),
        "drivable_segments_ok": mv.get("segments_ok"),
        "drivable_segments_total": mv.get("segments_total"),
        "walk_type_counts": (q.get("walk_type") or {}).get("counts"),
        "walk_type_unclassified": (q.get("walk_type") or {}).get("unclassified_counts"),
        "anchor": c.get("anchor"),
        "total_api_calls": data.get("total_api_calls"),
        "elapsed_s": data.get("elapsed_s"),
        "success": data.get("success"),
        "error_code": data.get("error_code"),
        "error": data.get("error"),
    }


def main():
    health = _get("/api/health")
    print(f"health: version={health.get('version')} pid={health.get('pid')} "
          f"started_at={health.get('started_at')} features={health.get('features')}")
    if not (health.get("features") or {}).get("anchor_loop"):
        raise SystemExit("后端不是含 anchor_loop 的新进程，先重启后端")

    device = "regress-n-" + uuid.uuid4().hex
    rows = []
    for case in CASES:
        payload = {
            "origin": {"lng": ANCHORS[0][0], "lat": ANCHORS[0][1]},
            "target_m": case["target_m"],
            "tol_m": 500,
            "seeds": case["seeds"],
            "max_candidates": 1,
            "max_api_calls": 800,
        }
        if case.get("anchors"):
            payload["anchors"] = case["anchors"]
        if case.get("verify_drivable"):
            payload["verify_drivable"] = True
        t0 = time.time()
        status, data = _post("/api/route/generate", payload, device)
        wall = round(time.time() - t0, 1)
        row = {"name": case["name"], "target_m": case["target_m"],
               "http_status": status, "wall_s": wall}
        if status == 200:
            row.update(_extract(data))
        else:
            row.update({"success": False, "error_code": data.get("error_code"),
                        "error": data.get("error")})
        rows.append(row)
        print(f"{case['name']}: http={status} dist={row.get('distance_m')} "
              f"err={row.get('error_m')} within={row.get('within_tolerance')} "
              f"closure={row.get('closure_m')} turns={row.get('turns')} "
              f"calls={row.get('total_api_calls')} wall={wall}s")

    # 诚实性硬检查：没有真实照明/车流/路宽数据时，安全/车流分必须不可用
    violations = []
    for r in rows:
        if r.get("road_safety_available") or r.get("traffic_available"):
            violations.append(f"{r['name']}: 安全/车流分不应可用")
        if r.get("success") and r.get("within_tolerance") is None:
            violations.append(f"{r['name']}: 缺少 within_tolerance")

    result = {"base_url": BASE, "health": health, "cases": rows,
              "honesty_violations": violations,
              "generated_by": "tools/regress_phase_n_anchor.py"}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print(f"\n写入 {OUT}")
    if violations:
        print("诚实性检查失败：", violations)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
