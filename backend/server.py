#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RunLoop 路线规划后端 API（Flask，阶段 K 生产化）。

安全模型（用户规范第六/十部分，部署形态 = 本机 waitress + Tailscale Serve）：
- 高德 Web 服务 Key 只在服务端读取：环境变量 RUNLOOP_AMAP_KEY 优先，
  否则 config/amap_key.local；绝不进入响应、日志、异常文本。
- 生产入口 = waitress（backend/serve.py），仅监听 127.0.0.1:8000，
  由 Tailscale Serve 代理为 Tailnet 内 HTTPS；不再默认暴露校园局域网。
- 每设备限流（X-Device-Id 或 Tailnet IP）+ 端点并发闸 + 高德配额熔断器。
- 日志脱敏：设备号 sha256 前 8 位、坐标 2 位小数；RotatingFileHandler 轮转。

启动：
    生产（Tailscale Serve 后端）：python backend/serve.py
    局域网调试（显式）：          RUNLOOP_HOST=0.0.0.0 python backend/server.py

接口：
    GET  /api/health          健康检查（v0.5：env/uptime/熔断状态）
    POST /api/route/generate  闭环路线生成（支持 fix_detours 绕行修复）
    POST /api/route/pois      沿途 POI 地标
"""
import json
import logging
import logging.handlers
import os
import sys
import threading
import time
import urllib.parse
import urllib.request

from flask import Flask, g, jsonify, request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

from backend.guard import (  # noqa: E402
    CircuitBreaker, ConcurrencyGate, RateLimiter, THROTTLE_CODES,
    hash_device, looks_throttled, sanitize_origin,
)
from backend.route_generator import (  # noqa: E402
    AmapWalkingPlanner,
    GenerateOptions,
    generate_candidates,
)
from backend.route_generator.nav_text import build_nav_instructions  # noqa: E402
from backend.route_generator.overlap import detect_overlaps  # noqa: E402
from backend.route_generator.sampling import sample_points_by_distance  # noqa: E402

KEY_FILE = os.path.join(ROOT, "config", "amap_key.local")
SERVICE_VERSION = "0.5"
MAX_BODY_BYTES = 256 * 1024
MAX_API_CALLS_CLAMP = 1500      # 决策#2：质量优先，预算上限放宽（原 1200）
DEFAULT_MAX_API_CALLS = 800

_key_cache = {"key": None}


def is_production() -> bool:
    """RUNLOOP_ENV=development 时才回显异常细节；默认按生产处理。"""
    return os.environ.get("RUNLOOP_ENV", "production").lower() != "development"


def load_key() -> str:
    """环境变量优先（部署机可不落盘），文件兜底（开发机现状）。"""
    env_key = os.environ.get("RUNLOOP_AMAP_KEY", "").strip()
    if env_key:
        return env_key
    if _key_cache["key"]:
        return _key_cache["key"]
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                _key_cache["key"] = line
                return line
    raise RuntimeError("未找到高德 Web 服务 Key（RUNLOOP_AMAP_KEY 或 config/amap_key.local）")


class _GuardState:
    """每 app 实例一份防护状态（测试可重建，互不污染）。"""

    def __init__(self):
        self.limiter = RateLimiter()
        self.breaker = CircuitBreaker(threshold=3, cooldown_s=120.0)
        self.gate = ConcurrencyGate()
        self.started_at = time.time()
        self.served = 0


def _err(status: int, code: str, message: str, retry_after: int = 0):
    resp = jsonify({"success": False, "error": message, "error_code": code,
                    **({"retry_after_s": retry_after} if retry_after else {})})
    resp.status_code = status
    if retry_after:
        resp.headers["Retry-After"] = str(retry_after)
    return resp


def create_app() -> Flask:
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_BODY_BYTES
    app.json.ensure_ascii = False
    state = _GuardState()
    app.extensions["runloop_guard"] = state

    # ---- 日志：轮转文件 + 控制台；werkzeug 原生访问日志降噪 ----
    log_dir = os.path.join(ROOT, "logs")
    os.makedirs(log_dir, exist_ok=True)
    file_handler = logging.handlers.RotatingFileHandler(
        os.path.join(log_dir, "runloop-api.log"),
        maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8")
    file_handler.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s"))
    app.logger.addHandler(file_handler)
    app.logger.setLevel(logging.INFO)
    logging.getLogger("werkzeug").setLevel(logging.WARNING)

    # POI 缓存：(lng,lat,radius) -> (expire_ts, data)
    poi_cache: dict = {}
    poi_lock = threading.Lock()

    def _device_key() -> str:
        dev = request.headers.get("X-Device-Id")
        if dev:
            return dev
        addr = request.remote_addr or ""
        # Tailscale Serve 反代后 remote_addr 恒为回环；用 X-Forwarded-For 还原
        # 真实 Tailnet 客户端 IP，保证每客户端配额不因反代合并成一个桶。
        # 安全前提：服务端仅监听 127.0.0.1，能设置 XFF 的只有本机 Serve 代理，
        # 外网无法伪造（直连者必然来自回环本身）。
        if addr in ("127.0.0.1", "::1"):
            xff = request.headers.get("X-Forwarded-For", "")
            first = xff.split(",")[0].strip() if xff else ""
            if first:
                return first
        return addr or "anon"

    @app.before_request
    def _mark_t0():
        g.t0 = time.perf_counter()

    @app.before_request
    def _guard():
        path = request.path
        g.gate_path = None
        if path == "/api/health" or not path.startswith("/api/"):
            return None
        dev = _device_key()
        g.dev = hash_device(dev)
        ok, retry = state.breaker.allow()
        if not ok:
            return _err(503, "UPSTREAM_QUOTA",
                        "高德配额熔断保护中（上游限流），请稍后重试", retry)
        ok, retry = state.limiter.check(path, dev)
        if not ok:
            return _err(429, "RATE_LIMITED", "请求过于频繁，请稍后重试", retry)
        if not state.gate.acquire(path):
            return _err(429, "SERVER_BUSY",
                        "服务器忙（路线生成并发已满），请稍后重试", 30)
        g.gate_path = path
        return None

    @app.teardown_request
    def _release(exc):
        path = getattr(g, "gate_path", None)
        if path:
            state.gate.release(path)

    @app.after_request
    def _access_log(resp):
        if request.path != "/api/health":
            app.logger.info(
                "dev=%s %s %s -> %d %sms%s",
                getattr(g, "dev", "-"), request.method, request.path,
                resp.status_code,
                round((time.perf_counter() - getattr(g, "t0", time.perf_counter())) * 1000),
                f" extra={g.log_extra}" if getattr(g, "log_extra", None) else "")
        return resp

    @app.errorhandler(413)
    def _too_large(e):
        return _err(413, "PAYLOAD_TOO_LARGE", "请求体超过 256KB 限制")

    @app.errorhandler(404)
    def _not_found(e):
        return _err(404, "NOT_FOUND", "接口不存在")

    @app.errorhandler(500)
    def _internal(e):
        app.logger.exception("unhandled error")
        return _err(500, "INTERNAL", "服务器内部错误")

    # ---- 序列化（客户端契约不变，字段只增不改） ----

    def _downsample(points, step=2):
        """折线降采样，减少 JSON 体积（保留首尾）。"""
        if len(points) <= step:
            return points
        out = points[::step]
        if out[-1] != points[-1]:
            out.append(points[-1])
        return out

    def _serialize_steps(segments):
        """把分段 steps 转成自然语言导航（含累计里程与转向）。"""
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
            "recommended": bool(c.recommended),
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
            "metrics": c.metrics or {},
            "polyline": [[round(p[0], 6), round(p[1], 6)] for p in poly],
            "overlaps": detect_overlaps(poly),
            "steps": _serialize_steps(loop.segments),
        }

    # ---- 路由 ----

    @app.route("/api/health", methods=["GET"])
    def health():
        return jsonify({
            "status": "ok",
            "service": "runloop-route-api",
            "version": SERVICE_VERSION,
            "env": "development" if not is_production() else "production",
            "uptime_s": round(time.time() - state.started_at, 1),
            "breaker": state.breaker.state,
            "served": state.served,
        })

    @app.route("/api/client-config", methods=["GET"])
    def client_config():
        """远程配置（App 启动时拉取并缓存 24h）：不发版即可微调的客户端参数。

        只下发非敏感调优项；公告文本可用 RUNLOOP_ANNOUNCEMENT 环境变量注入。
        """
        return jsonify({
            "success": True,
            "config": {
                "service_version": SERVICE_VERSION,
                "announcement": os.environ.get("RUNLOOP_ANNOUNCEMENT", ""),
                "generate": {"max_api_calls": DEFAULT_MAX_API_CALLS,
                             "sleep_s": 0.05},
                "pois": {"interval_m": 1000, "radius": 500, "limit": 3},
            },
        })

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
            points = int(data.get("points", 0))  # 0 = 按目标距离自适应
            detour = float(data.get("detour_factor", 1.7))
            max_candidates = int(data.get("max_candidates", 1))
            max_api_calls = int(data.get("max_api_calls", DEFAULT_MAX_API_CALLS))
            sleep_s = float(data.get("sleep_s", 0.05))
            fix_detours = bool(data.get("fix_detours", True))
        except (TypeError, ValueError, AttributeError) as e:
            return _err(400, "BAD_REQUEST",
                        "参数错误" if is_production() else f"参数错误：{e}")

        if not (-180 <= lng <= 180 and -90 <= lat <= 90):
            return _err(400, "BAD_ORIGIN", "origin 坐标非法")
        if not (1000 <= target_m <= 50000):
            return _err(400, "BAD_TARGET", "target_m 需在 1000~50000 米之间")
        # 容差硬约束（决策#1）：±500m 绝对容差不放松，也不允许客户端缩小到病态
        tol_m = max(100, min(500, tol_m))

        try:
            key = load_key()
        except Exception:  # noqa: BLE001
            app.logger.error("dev=%s key_missing", getattr(g, "dev", "-"))
            return _err(500, "KEY_MISSING", "服务器未配置高德 Key")

        try:
            planner = AmapWalkingPlanner(key, sleep=0.15, timeout=30)
            options = GenerateOptions(
                target_m=target_m,
                n_points=points,
                seeds=seeds,
                tol_m=tol_m,
                max_iters=8,
                detour_factor=detour,
                sleep_s=sleep_s,
                max_candidates=max(1, min(3, max_candidates)),
                max_api_calls=max(50, min(MAX_API_CALLS_CLAMP, max_api_calls)),
                fix_detours=fix_detours,
            )
            result = generate_candidates(planner, (lng, lat), options)
        except Exception as e:  # noqa: BLE001
            if looks_throttled(str(e)):
                state.breaker.record_throttle()
            app.logger.exception("dev=%s generate_crash", getattr(g, "dev", "-"))
            detail = "" if is_production() else f"：{type(e).__name__}: {e}"
            return _err(500, "GENERATE_ERROR", f"路线生成失败{detail}")

        candidates = [_serialize_candidate(c, target_m, tol_m) for c in result.candidates]
        ok_candidates = [c for c in candidates if c.get("ok")]

        # 熔断反馈：候选错误命中限流 infocode → 计数；有成功候选 → 复位
        throttled = any(looks_throttled(c.get("error")) for c in candidates)
        if throttled and not ok_candidates:
            state.breaker.record_throttle()
        elif ok_candidates:
            state.breaker.record_success()
        state.served += 1
        g.log_extra = (f"target={target_m} calls={result.total_api_calls} "
                       f"ok={len(ok_candidates)}/{len(candidates)} "
                       f"origin={sanitize_origin(lng, lat)} "
                       f"throttled={'Y' if throttled else 'N'}")

        if not ok_candidates:
            return jsonify({
                "success": False,
                "error": "所有候选路线均生成失败（请检查坐标是否在可步行路网内）",
                "error_code": "NO_ROUTE",
                "target_m": target_m,
                "tol_m": tol_m,
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

        body: {"polyline": [[lng,lat],...], "interval_m": 1000, "radius": 500, "limit": 3}
        """
        try:
            data = request.get_json(force=True, silent=True) or {}
            polyline = data.get("polyline") or []
            interval_m = float(data.get("interval_m", 1000))
            radius = int(data.get("radius", 500))
            limit = int(data.get("limit", 3))
            max_points = int(data.get("max_points", 18))
        except (TypeError, ValueError) as e:
            return _err(400, "BAD_REQUEST",
                        "参数错误" if is_production() else f"参数错误：{e}")

        if len(polyline) < 2:
            return jsonify({"success": True, "results": []})

        try:
            key = load_key()
        except Exception:  # noqa: BLE001
            return _err(500, "KEY_MISSING", "服务器未配置高德 Key")

        try:
            pts = [(float(p[0]), float(p[1])) for p in polyline]
        except (TypeError, ValueError, IndexError):
            return _err(400, "BAD_POLYLINE", "polyline 格式错误")

        # 沿路线累计距离采样（每 interval_m 米取一个查询点）
        samples = [
            (p[0], p[1], cum)
            for (p, cum) in sample_points_by_distance(pts, interval_m, max_points)
        ]

        results = []
        throttle_hit = False
        for lng, lat, cum in samples:
            ck = (round(lng, 5), round(lat, 5), radius)
            now = time.time()
            hit = poi_cache.get(ck)
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
                req = urllib.request.Request(url, headers={"User-Agent": "RunLoop/0.5"})
                with urllib.request.urlopen(req, timeout=15) as resp:
                    raw = json.loads(resp.read().decode("utf-8"))
                pois_list = []
                if str(raw.get("status")) == "1":
                    for p in (raw.get("pois") or [])[:limit]:
                        pois_list.append({
                            "name": p.get("name") or "",
                            "type": p.get("type") or "",
                            "distance_m": float(p.get("distance") or 0),
                        })
                else:
                    infocode = str(raw.get("infocode") or "")
                    if infocode in THROTTLE_CODES:
                        throttle_hit = True
                with poi_lock:
                    poi_cache[ck] = (now + 3600, pois_list)
                results.append({"cumulative_m": cum, "lng": lng, "lat": lat, "pois": pois_list})
            except Exception:  # noqa: BLE001
                results.append({"cumulative_m": cum, "lng": lng, "lat": lat, "pois": []})
        if throttle_hit:
            state.breaker.record_throttle()
        elif results:
            state.breaker.record_success()
        g.log_extra = f"pois samples={len(samples)} throttled={'Y' if throttle_hit else 'N'}"
        return jsonify({"success": True, "results": results})

    return app


app = create_app()


def main():
    """开发调试入口（Flask dev server）。生产请用 python backend/serve.py。"""
    host = os.environ.get("RUNLOOP_HOST", "127.0.0.1")
    port = int(os.environ.get("RUNLOOP_PORT", "8000"))
    dev = not is_production()
    print(f"RunLoop 路线 API（开发模式）：http://{host}:{port}")
    if host == "127.0.0.1":
        print("提示：默认仅监听本机（供 Tailscale Serve 代理）。")
        print("      局域网真机调试需显式设置 RUNLOOP_HOST=0.0.0.0（校园网可见，注意安全）。")
    app.run(host=host, port=port, threaded=True, debug=dev)


if __name__ == "__main__":
    main()
