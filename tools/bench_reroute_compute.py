#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 M-G：后端重规划**纯计算开销**基准（任务书 7.3）。

诚实边界：生产环境的重规划耗时由真实高德步行 API 网络延迟主导
（每次偏航 1–5 次候选规划）。本机无法打真实 API——这里用零延迟
planner 替身测量**算法本身**的开销（候选采样/评分/合并/序列化），
证明算法层不会成为瓶颈；真实端到端耗时由后端响应的 elapsed_s 与
App VoiceLog 在真机实测（列入待验证清单）。

运行：python tools/bench_reroute_compute.py
"""
import math
import os
import statistics
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from backend.reroute import _cumulative, pick_rejoin_candidates, reroute  # noqa: E402
from backend.route_generator.geo import haversine  # noqa: E402
from backend.route_generator.types import PlanResult, PlanStep  # noqa: E402


class ZeroLatencyPlanner:
    """零网络延迟替身：直线插值 10 点 + 单 step，几何量级与真实响应一致。"""

    def __init__(self, factor=1.15):
        self.factor = factor
        self.calls = 0

    def plan_walking(self, origin, destination) -> PlanResult:
        self.calls += 1
        d = haversine(origin, destination) * self.factor
        pts = []
        for k in range(11):
            t = k / 10.0
            pts.append((origin[0] + (destination[0] - origin[0]) * t,
                        origin[1] + (destination[1] - origin[1]) * t))
        step = PlanStep(instruction="沿连接道路前进", road="连接道路",
                        distance_m=d, action="左转", polyline=pts)
        return PlanResult(distance_m=d, duration_s=d / 1.2,
                          points=pts, steps=[step])


def build_loop(radius_m=800.0, n=1200, lat0=30.5364, lng0=114.3684):
    """5km 级 8 字环线（≈1200 点，与真实服务端折线密度一致）。"""
    pts = []
    cos_lat = math.cos(math.radians(lat0))
    for i in range(n):
        a = 2 * math.pi * i / n
        x = radius_m * math.sin(a)
        y = radius_m * math.sin(a) * math.cos(a)
        pts.append((lng0 + x / (111320.0 * cos_lat), lat0 + y / 110574.0))
    return pts


def total_len(pts):
    return sum(haversine(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def main():
    poly = build_loop()
    total = total_len(poly)
    along = total * 0.55
    # 取里程 55% 处的真实折线点作为当前位置
    origin = poly[0]
    acc = 0.0
    for i in range(len(poly) - 1):
        acc += haversine(poly[i], poly[i + 1])
        if acc >= along:
            origin = poly[i]
            break

    print(f"路线总长 {total:.0f}m / {len(poly)} 点；along={along:.0f}m；"
          f"target=5000m；budget=5")

    # ---- 单次端到端（算法层） ----
    times = []
    ok = 0
    for _ in range(30):
        planner = ZeroLatencyPlanner()
        t0 = time.perf_counter()
        res = reroute(planner, origin, poly, along, 5000.0, along,
                      tol_m=500.0, max_calls=5)
        times.append((time.perf_counter() - t0) * 1000)
        ok += 1 if res.ok else 0
    print(f"[PERF-PY] reroute() 算法层 ×30 次: ok={ok}/30 "
          f"mean={statistics.mean(times):.2f}ms "
          f"p50={statistics.median(times):.2f}ms "
          f"p95={sorted(times)[28]:.2f}ms max={max(times):.2f}ms")

    # ---- 候选采样单独计时 ----
    cum = _cumulative(poly)
    times2 = []
    for _ in range(30):
        t0 = time.perf_counter()
        cands = pick_rejoin_candidates(poly, cum, along, None, 5)
        times2.append((time.perf_counter() - t0) * 1000)
    print(f"[PERF-PY] pick_rejoin_candidates ×30: "
          f"mean={statistics.mean(times2):.2f}ms "
          f"p95={sorted(times2)[28]:.2f}ms (候选数={len(cands)})")

    # 断言：算法层开销必须远小于真实 API 一次往返（~200-800ms）
    assert statistics.mean(times) < 50, "算法层开销异常"
    print("结论：算法层开销 <50ms/次，端到端耗时由真实高德 API 网络延迟主导"
          "（真机 elapsed_s 见待验证清单）。")


if __name__ == "__main__":
    main()
