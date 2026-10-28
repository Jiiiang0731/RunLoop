#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RunLoop 路线规划后端 API（Flask）。

封装 backend/route_generator 的闭环路线算法，供手机端调用。
- 高德 Web 服务 Key 仅在此后端读取（config/amap_key.local），不进入 APK、不提交 Git。
- 监听地址/端口可通过环境变量配置：RUNLOOP_HOST / RUNLOOP_PORT。

启动（局域网联调）：
    python backend/server.py
    # 默认监听 0.0.0.0:8000，手机与电脑同一 Wi-Fi 时用 http://<电脑局域网IP>:8000 访问

接口：
    GET  /api/health
    POST /api/route/generate
    POST /api/route/pois
"""
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request

from flask import Flask, jsonify, request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner,
    GenerateOptions,
    generate_candidates,
)
from backend.route_generator.nav_text import build_nav_instructions  # noqa: E402
from backend.route_generator.overlap import detect_overlaps  # noqa: E402
from backend.route_generator.sampling import sample_points_by_distance  # noqa: E402

KEY_FILE = os.path.join(ROOT, "config", "amap_key.local")

app = Flask(__name__)
_key_cache = {"key": None}

# POI 缓存：(lng,lat,radius) -> (expire_ts, data)
_poi_cache: dict = {}
_poi_lock = threading.Lock()
_POI_TTL = 3600


def load_key() -> str:
    if _key_cache["key"]:
        return _key_cache["key"]
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                _key_cache["key"] = line
                return line
    raise RuntimeError("未找到高德 Web 服务 Key（config/amap_key.local）")


def _downsample(points, step=2):
    """折线降采样，减少 JSON 体积（保留首尾）。"""
    if len(points) <= step:
        return points
    out = points[::step]
    if out[-1] != points[-1]:
        out.append(points[-1])
    return out


def _serialize_steps(segments):
    """把分段 steps 转成自然语言导航（含累计里程与转向，不再依赖方位词）。"""
    all_steps = []
    for seg in segments:
        all_steps.extend(seg.steps)
    nav = build_nav_instructions(all_steps)
    out = []
    for item in nav:
        out.append({
            "instruction": item["text"],
            "text": item["text"],
            "road": item["road"],
            "distance_m": item["distance_m"],
            "cumulative_m": item["cumulative_m"],
            "action": item["turn"],
            "turn": item["turn"],
            "orientation": "",
            "junction": item["junction"],
            "polyline": [],
        })
    return out


def _serialize_candidate(c, target_m, tol_m):
    if c.loop is None:
        return {"seed": c.seed, "ok": False, "error": c.error or "无法生成闭环"}
    loop = c.loop
    score = c.score
    err = loop.distance_m - target_m
    within = abs(err) <= tol_m
    score_components = []
    if score:
        for comp in score.components:
            score_components.append({
                "name": comp.name,
                "score": comp.score,
                "weight": comp.weight,
                "available": comp.available,
                "detail": comp.detail,
            })
    poly = _downsample(loop.polyline, 2)
    return {
        "seed": c.seed,
        "ok": True,
        "distance_m": round(loop.distance_m, 1),
        "error_m": round(err, 1),
        "within_tolerance": within,
        "closure_m": loop.closure_m,
        "closure_ok": loop.closure_m < 50,
        "start_snap_m": loop.start_snap_m,
        "duration_s": round(loop.duration_s, 1),
        "n_points": len(loop.polyline),
        "segments_count": len(loop.segments),
        "score": score.total if score else None,
        "score_components": score_components,
        "polyline": [[round(p[0], 6), round(p[1], 6)] for p in poly],
        "overlaps": detect_overlaps(poly),
        "steps": _serialize_steps(loop.segments),
    }


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "runloop-route-api", "version": "0.3"})


@app.route("/api/route/generate", methods=["POST"])
def generate():
    t0 = time.time()
    try:
        data = request.get_json(force=True, silent=True) or {}
        origin = data.get("origin") or {}
        lng = float(origin.get("lng"))
        lat = float(origin.get("lat"))
        target_m = int(data.get("target_m", 15000))
        tol_m = int(data.get("tol_m", 500))
        seeds = data.get("seeds") or [1]
        seeds = [int(s) for s in seeds][:3]
        points = int(data.get("points", 10))
        detour = float(data.get("detour_factor", 1.7))
        max_candidates = int(data.get("max_candidates", 1))
        max_api_calls = int(data.get("max_api_calls", 600))
    except (TypeError, ValueError) as e:
        return jsonify({"success": False, "error": f"参数错误：{e}", "error_code": "BAD_REQUEST"}), 400

    if not (-180 <= lng <= 180 and -90 <= lat <= 90):
        return jsonify({"success": False, "error": "origin 坐标非法", "error_code": "BAD_ORIGIN"}), 400
    if not (1000 <= target_m <= 50000):
        return jsonify({"success": False, "error": "target_m 需在 1000~50000 米之间", "error_code": "BAD_TARGET"}), 400

    try:
        key = load_key()
        planner = AmapWalkingPlanner(key)
        options = GenerateOptions(
            target_m=target_m,
            n_points=points,
            seeds=seeds,
            tol_m=tol_m,
            max_iters=8,
            detour_factor=detour,
            sleep_s=0.02,
            max_candidates=max(1, min(3, max_candidates)),
            max_api_calls=max(50, min(1200, max_api_calls)),
        )
        result = generate_candidates(planner, (lng, lat), options)
    except Exception as e:  # noqa: BLE001
        return jsonify({
            "success": False,
            "error": f"路线生成失败：{type(e).__name__}: {e}",
            "error_code": "GENERATE_ERROR",
        }), 500

    candidates = [_serialize_candidate(c, target_m, tol_m) for c in result.candidates]
    ok_candidates = [c for c in candidates if c.get("ok")]
    if not ok_candidates:
        return jsonify({
            "success": False,
            "error": "所有候选路线均生成失败（请检查坐标是否在可步行路网内）",
            "error_code": "NO_ROUTE",
            "candidates": candidates,
        }), 200

    return jsonify({
        "success": True,
        "origin": {"lng": lng, "lat": lat},
        "target_m": target_m,
        "tol_m": tol_m,
        "seeds": seeds,
        "total_api_calls": result.total_api_calls,
        "elapsed_s": round(time.time() - t0, 1),
        "stage_times": result.stage_times,
        "candidates": candidates,
    })


@app.route("/api/route/pois", methods=["POST"])
def pois():
    """按路线累计里程采样，查询沿途真实 POI（带 1 小时缓存）。

    body: {"polyline": [[lng,lat],...], "interval_m": 1000, "radius": 300, "limit": 3}
    返回按累计里程排序的地标（覆盖前/中/后段）。
    """
    try:
        data = request.get_json(force=True, silent=True) or {}
        polyline = data.get("polyline") or []
        interval_m = float(data.get("interval_m", 1000))
        radius = int(data.get("radius", 500))
        limit = int(data.get("limit", 3))
        max_points = int(data.get("max_points", 18))
    except (TypeError, ValueError) as e:
        return jsonify({"success": False, "error": f"参数错误：{e}"}), 400

    if len(polyline) < 2:
        return jsonify({"success": True, "results": []})

    try:
        key = load_key()
    except Exception as e:  # noqa: BLE001
        return jsonify({"success": False, "error": str(e)}), 500

    try:
        pts = [(float(p[0]), float(p[1])) for p in polyline]
    except (TypeError, ValueError, IndexError):
        return jsonify({"success": False, "error": "polyline 格式错误"}), 400

    # 沿路线累计距离采样（每 interval_m 米取一个查询点）
    samples = [
        (p[0], p[1], cum)
        for (p, cum) in sample_points_by_distance(pts, interval_m, max_points)
    ]

    results = []
    for lng, lat, cum in samples:
        ck = (round(lng, 5), round(lat, 5), radius)
        now = time.time()
        with _poi_lock:
            hit = _poi_cache.get(ck)
            if hit and hit[0] > now:
                results.append({"cumulative_m": cum, "lng": lng, "lat": lat, "pois": hit[1]})
                continue
        q = urllib.parse.urlencode({
            "location": f"{lng:.6f},{lat:.6f}",
            "radius": radius,
            "key": key,
            "offset": limit,
            "page": 1,
        })
        url = f"https://restapi.amap.com/v3/place/around?{q}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "RunLoop/0.3"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = json.loads(resp.read().decode("utf-8"))
            pois = []
            if str(raw.get("status")) == "1":
                for p in (raw.get("pois") or [])[:limit]:
                    pois.append({
                        "name": p.get("name") or "",
                        "type": p.get("type") or "",
                        "distance_m": float(p.get("distance") or 0),
                    })
            with _poi_lock:
                _poi_cache[ck] = (now + _POI_TTL, pois)
            results.append({"cumulative_m": cum, "lng": lng, "lat": lat, "pois": pois})
        except Exception:  # noqa: BLE001
            results.append({"cumulative_m": cum, "lng": lng, "lat": lat, "pois": []})
    return jsonify({"success": True, "results": results})


def main():
    host = os.environ.get("RUNLOOP_HOST", "0.0.0.0")
    port = int(os.environ.get("RUNLOOP_PORT", "8000"))
    print(f"RunLoop 路线 API 启动：http://{host}:{port}")
    print("局域网联调：手机与电脑同一 Wi-Fi，手机访问 http://<电脑局域网IP>:%d" % port)
    app.run(host=host, port=port, threaded=True)


if __name__ == "__main__":
    main()
