#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N 只读诊断：用**真实高德 API** 复现并度量短距离路线问题。

目的（对应任务书一问/二问）：
- 为什么 1km 只有 0.4–0.6km：看候选距离、误差、校准历史与提前终止点；
- 为什么总进小路/碎片：统计真实 steps 的道路名结构（无名路占比、
  step 中位长度、不同道路数/km）——只做客观计数，不编造安全结论；
- 步行（v3 walking）与骑行（v4 bicycling）同条件对比，作为「跑步道路
  选择」的代理指标证据（骑行规划天然避开人行台阶/院内小路）。

调用量控制：每个组合上限 60 次高德调用，脚本结束时打印总次数。
不写任何代码到产品路径；只读 + 证据。

运行：python tools/diag_phase_n_routes.py [--origin lng,lat] [--targets 1000,2500,5000]
"""
import argparse
import json
import os
import statistics
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from backend.route_generator.generator import generate_candidates  # noqa: E402
from backend.route_generator.geo import haversine  # noqa: E402
from backend.route_generator.planner import AmapWalkingPlanner, MapPlanner  # noqa: E402
from backend.route_generator.types import (  # noqa: E402
    GenerateOptions, PlanResult, PlanStep,
)

KEY_FILE = os.path.join(ROOT, "config", "amap_key.local")


def load_key() -> str:
    env = os.environ.get("RUNLOOP_AMAP_KEY", "").strip()
    if env:
        return env
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("缺少高德 Key")


class AmapBicyclingPlanner(MapPlanner):
    """v4 骑行规划（原型，仅诊断用）：作为「跑步道路质量」的代理对比。

    AMap v4 骑行返回 errcode（0=OK），steps 含 instruction/road/distance/
    duration/polyline。不含行动作字段（action），导航动作由客户端按几何/
    指令文本解析——本原型只用于距离与道路结构统计。
    """

    def __init__(self, key: str, base: str = "https://restapi.amap.com",
                 retries: int = 2, sleep: float = 0.2, timeout: int = 20):
        self.key = key
        self.base = base
        self.retries = retries
        self.sleep = sleep
        self.timeout = timeout
        self._http_calls = 0
        self._cache = {}

    @property
    def http_calls(self) -> int:
        return self._http_calls

    def _http(self, url: str) -> dict:
        import urllib.request
        req = urllib.request.Request(url, headers={"User-Agent": "RunLoop/0.4-diag"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def plan_walking(self, origin, dest) -> PlanResult:  # 接口名统一（生成器只认这个）
        ck = (round(origin[0], 6), round(origin[1], 6),
              round(dest[0], 6), round(dest[1], 6))
        if ck in self._cache:
            return self._cache[ck]
        q = f"origin={origin[0]:.6f},{origin[1]:.6f}&destination={dest[0]:.6f},{dest[1]:.6f}&key={self.key}"
        url = f"{self.base}/v4/direction/bicycling?{q}"
        last = "unknown"
        for attempt in range(self.retries + 1):
            self._http_calls += 1
            try:
                data = self._http(url)
            except Exception as e:  # noqa: BLE001
                last = f"exception:{type(e).__name__}"
                time.sleep(self.sleep * (2 ** attempt))
                continue
            if str(data.get("errcode")) == "0" and (data.get("data") or {}).get("paths"):
                p = data["data"]["paths"][0]
                steps = []
                pts = []
                for s in p.get("steps", []) or []:
                    pl = []
                    for chunk in (s.get("polyline") or "").split(";"):
                        parts = chunk.strip().split(",")
                        if len(parts) >= 2:
                            try:
                                pl.append((float(parts[0]), float(parts[1])))
                            except ValueError:
                                pass
                    pts.extend(pl)
                    steps.append(PlanStep(
                        instruction=str(s.get("instruction") or ""),
                        road=str(s.get("road") or ""),
                        distance_m=float(s.get("distance") or 0),
                        duration_s=float(s.get("duration") or 0),
                        action="", orientation="", polyline=pl))
                res = PlanResult(
                    distance_m=float(p.get("distance") or 0),
                    duration_s=float(p.get("duration") or 0),
                    points=pts, steps=steps)
                self._cache[ck] = res
                return res
            last = f"errcode={data.get('errcode')} errmsg={data.get('errmsg')}"
            time.sleep(self.sleep * (2 ** attempt))
        return PlanResult(error=last)


def road_stats(loop) -> dict:
    """真实 steps 的道路结构统计（只计数，不做「安全」结论）。"""
    steps = [s for seg in loop.segments for s in seg.steps]
    roads = [s.road.strip() for s in steps if s.road and s.road.strip()]
    dists = [s.distance_m for s in steps if s.distance_m > 0]
    total = sum(dists) or 1.0
    unnamed = sum(s.distance_m for s in steps if not (s.road or "").strip())
    short = sum(s.distance_m for s in steps if 0 < s.distance_m < 40)
    return {
        "steps": len(steps),
        "distinct_roads": len(set(roads)),
        "roads_per_km": round(len(set(roads)) / max(loop.distance_m / 1000.0, 0.001), 2),
        "median_step_m": round(statistics.median(dists), 1) if dists else 0.0,
        "short_step_ratio": round(short / total, 3),
        "unnamed_ratio": round(unnamed / total, 3),
        "roads": roads[:12],
    }


def geo_len(polyline) -> float:
    return sum(haversine(polyline[i - 1], polyline[i])
               for i in range(1, len(polyline)))


def run_case(label: str, planner, origin, target: int, seeds, max_calls: int = 60):
    t0 = time.time()
    opts = GenerateOptions(target_m=target, seeds=seeds, max_candidates=1,
                           max_api_calls=max_calls, tol_m=500, sleep_s=0.0,
                           per_seed_calls=max_calls)
    try:
        res = generate_candidates(planner, origin, opts)
    except Exception as e:  # noqa: BLE001
        print(f"[{label}] target={target} EXCEPTION {e}")
        return None
    print(f"\n[{label}] target={target}m seeds={seeds} "
          f"calls={res.total_api_calls} elapsed={res.total_elapsed_s:.1f}s")
    for c in res.candidates:
        if c.loop is None or c.loop.error:
            print(f"  seed={c.seed} FAILED err={c.error or (c.loop.error if c.loop else '?')}")
            continue
        L = c.loop
        err = L.distance_m - target
        g = geo_len(L.polyline)
        st = road_stats(L)
        m = c.metrics or {}
        print(f"  seed={c.seed} AMap距离={L.distance_m:.0f}m 几何={g:.0f}m "
              f"误差={err:+.0f}m ({(err/target):+.1%}) 闭合={L.closure_m:.0f}m "
              f"评分={c.score.total if c.score else '-'}")
        print(f"    turns={m.get('turns')} density={m.get('turn_density')} "
              f"uturn={m.get('uturns')} sharp={m.get('sharp_turns')} "
              f"rep={m.get('repetition_ratio')} straight300={m.get('straight_ratio_300')}")
        print(f"    steps={st['steps']} distinct_roads={st['distinct_roads']} "
              f"roads/km={st['roads_per_km']} median_step={st['median_step_m']}m "
              f"short_step_ratio={st['short_step_ratio']} unnamed={st['unnamed_ratio']}")
        print(f"    roads={st['roads']}")
        hist = [h for h in c.history if "distance" in h]
        for h in hist[:4]:
            print(f"    hist {h.get('variant')}#{h.get('iter')} R={h.get('R')} "
                  f"d={h.get('distance')} err={h.get('err')} score={h.get('score')}")
        yield_ = {"target": target, "seed": c.seed, "dist": L.distance_m,
                  "geo": g, "err": err, "metrics": m, "road": st,
                  "polyline": L.polyline, "history": c.history}
        return yield_
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--origin", default="114.03,30.54")
    ap.add_argument("--targets", default="1000,2500,5000")
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--modes", default="walk,bike")
    args = ap.parse_args()

    lng, lat = [float(x) for x in args.origin.split(",")]
    targets = [int(x) for x in args.targets.split(",")]
    seeds = [int(x) for x in args.seeds.split(",")]
    modes = args.modes.split(",")
    key = load_key()

    out = {"origin": [lng, lat], "cases": []}
    total = 0
    for mode in modes:
        planner = (AmapWalkingPlanner(key, sleep=0.15, timeout=20)
                   if mode == "walk"
                   else AmapBicyclingPlanner(key, sleep=0.15, timeout=20))
        label = "WALK(v3)" if mode == "walk" else "BIKE(v4)"
        for t in targets:
            before = planner.http_calls
            r = run_case(label, planner, (lng, lat), t, seeds)
            total += planner.http_calls - before
            if r:
                r["mode"] = mode
                out["cases"].append(r)

    os.makedirs(os.path.join(ROOT, "docs", "phase_n"), exist_ok=True)
    path = os.path.join(ROOT, "docs", "phase_n", "diag_routes.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    print(f"\n=== 实际高德调用合计 {total} 次；结果写入 {path}")


if __name__ == "__main__":
    main()
