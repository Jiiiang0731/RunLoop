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
        body: { "origin": {"lng": 114.087279, "lat": 30.536395},
                "target_m": 15000, "tol_m": 500, "seeds": [1,2,3],
                "points": 10, "detour_factor": 1.7 }
"""
import json
import os
import sys
import time

from flask import Flask, jsonify, request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner,
    GenerateOptions,
    generate_candidates,
)

KEY_FILE = os.path.join(ROOT, "config", "amap_key.local")

app = Flask(__name__)


def load_key() -> str:
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
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


def _serialize_candidate(c, target_m):
    if c.loop is None:
        return {
            "seed": c.seed,
            "ok": False,
            "error": c.error or "无法生成闭环",
        }
    loop = c.loop
    score = c.score
    return {
        "seed": c.seed,
        "ok": True,
        "distance_m": round(loop.distance_m, 1),
        "error_m": round(loop.distance_m - target_m, 1),
        "closure_m": loop.closure_m,
        "start_snap_m": loop.start_snap_m,
        "duration_s": round(loop.duration_s, 1),
        "n_points": len(loop.polyline),
        "segments_count": len(loop.segments),
        "score": score.total if score else None,
        "score_components": (
            [
                {
                    "name": comp.name,
                    "score": comp.score,
                    "weight": comp.weight,
                    "available": comp.available,
                    "detail": comp.detail,
                }
                for comp in score.components
            ]
            if score
            else []
        ),
        # 折线坐标：[[lng, lat], ...]，坐标系为 GCJ-02（高德）
        "polyline": [[round(p[0], 6), round(p[1], 6)] for p in _downsample(loop.polyline, 2)],
    }


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "runloop-route-api"})


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
        seeds = data.get("seeds") or [1, 2, 3]
        seeds = [int(s) for s in seeds][:3]
        points = int(data.get("points", 10))
        detour = float(data.get("detour_factor", 1.7))
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
        )
        result = generate_candidates(planner, (lng, lat), options)
    except Exception as e:  # noqa: BLE001
        return jsonify({
            "success": False,
            "error": f"路线生成失败：{type(e).__name__}: {e}",
            "error_code": "GENERATE_ERROR",
        }), 500

    candidates = [_serialize_candidate(c, target_m) for c in result.candidates]
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
        "candidates": candidates,
    })


def main():
    host = os.environ.get("RUNLOOP_HOST", "0.0.0.0")
    port = int(os.environ.get("RUNLOOP_PORT", "8000"))
    print(f"RunLoop 路线 API 启动：http://{host}:{port}")
    print("局域网联调：手机与电脑同一 Wi-Fi，手机访问 http://<电脑局域网IP>:%d" % port)
    app.run(host=host, port=port, threaded=True)


if __name__ == "__main__":
    main()
