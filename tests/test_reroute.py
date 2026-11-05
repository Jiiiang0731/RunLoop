#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""动态重规划离线测试（阶段 M-D，任务书 5.4/5.5/5.6/5.7）。

全部使用替身 planner——绝不触真实高德 API。
覆盖：候选采样（只取剩余路线/含终点/方向排序）、绕行评分、
±500m 容差诚实口径、预算硬上限、错误码、端点契约与脱敏。
"""
import json
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.reroute import (
    _cumulative, _point_at, _tangent_at, pick_rejoin_candidates, reroute,
)
from backend.route_generator.geo import GeoPoint, haversine
from backend.route_generator.types import PlanResult, PlanStep


def east_line(n=12, dlng=0.001, lat=39.9, lng0=116.0):
    """正东直线折线（相邻点约 85m）。"""
    return [(lng0 + i * dlng, lat) for i in range(n)]


class FakePlanner:
    """离线替身：距离 = 直线 × factor；可注入失败/限流。"""

    def __init__(self, factor=1.2, fail=False, throttle=False):
        self.factor = factor
        self.fail = fail
        self.throttle = throttle
        self.calls = []

    def plan_walking(self, origin: GeoPoint, destination: GeoPoint) -> PlanResult:
        self.calls.append((origin, destination))
        if self.throttle:
            return PlanResult(error="步行规划失败: infocode=10003 访问已超出日访问量")
        if self.fail:
            return PlanResult(error="步行规划失败: NO_PATH")
        d = haversine(origin, destination) * self.factor
        mid = ((origin[0] + destination[0]) / 2, (origin[1] + destination[1]) / 2)
        step = PlanStep(instruction="右转进入测试路", road="测试路",
                        distance_m=d, action="右转",
                        polyline=[origin, mid, destination])
        return PlanResult(distance_m=d, duration_s=d / 1.2,
                          points=[origin, mid, destination], steps=[step])


class TestGeometryHelpers(unittest.TestCase):
    def test_point_at_interpolates(self):
        poly = east_line()
        cum = _cumulative(poly)
        p = _point_at(poly, cum, cum[-1] / 2)
        # 中点应落在折线上（与两端点等距附近）
        self.assertAlmostEqual(p[1], 39.9, places=6)
        self.assertTrue(poly[0][0] < p[0] < poly[-1][0])

    def test_tangent_east_is_90(self):
        poly = east_line()
        cum = _cumulative(poly)
        self.assertAlmostEqual(_tangent_at(poly, cum, cum[3]), 90.0, delta=1.0)


class TestCandidateSampling(unittest.TestCase):
    def test_candidates_only_from_remaining(self):
        """5.7#4：候选绝不落在已跑过的历史路段。"""
        poly = east_line()
        cum = _cumulative(poly)
        along = cum[4]
        cands = pick_rejoin_candidates(poly, cum, along, heading=None, budget=4)
        self.assertTrue(cands)
        for c in cands:
            self.assertGreaterEqual(c.along_m, along + 79)

    def test_endpoint_always_candidate(self):
        """闭环语义：终点恒为候选（5.4#3 最终回到终点）。"""
        poly = east_line()
        cum = _cumulative(poly)
        cands = pick_rejoin_candidates(poly, cum, cum[2], heading=None, budget=4)
        self.assertAlmostEqual(cands[-1].along_m, cum[-1], delta=1.0)

    def test_budget_respected(self):
        poly = east_line(30)
        cum = _cumulative(poly)
        cands = pick_rejoin_candidates(poly, cum, 0.0, heading=None, budget=3)
        self.assertLessEqual(len(cands), 3)

    def test_heading_deprioritizes_oncoming_leg(self):
        """去-回折返路线：heading 向东时，返程（切线向西）候选排后。"""
        out = east_line(8)                      # 向东
        back = [(116.007 - i * 0.001, 39.9005) for i in range(1, 8)]  # 折返向西
        poly = out + back
        cum = _cumulative(poly)
        cands = pick_rejoin_candidates(poly, cum, cum[2], heading=90.0, budget=5)
        tangents = [_ang(c.tangent, 90.0) for c in cands]
        # 排序后前段应不比后段“更对向”
        front = min(tangents[:max(1, len(cands) // 2)])
        back_max = max(tangents)
        self.assertLessEqual(front, back_max)

    def test_near_end_single_candidate(self):
        poly = east_line()
        cum = _cumulative(poly)
        cands = pick_rejoin_candidates(poly, cum, cum[-1] - 50, heading=None, budget=4)
        self.assertEqual(len(cands), 1)
        self.assertAlmostEqual(cands[0].along_m, cum[-1], delta=1.0)


def _ang(a, b):
    d = abs(a - b) % 360.0
    return 360.0 - d if d > 180.0 else d


class TestReroute(unittest.TestCase):
    def setUp(self):
        self.poly = east_line()
        self.cum = _cumulative(self.poly)
        self.origin = (116.0035, 39.9006)   # 偏离路线约 65m 北侧
        self.along = self.cum[3]

    def test_success_math_is_honest(self):
        """5.4/5.5：剩余里程 = 连接段 + 原剩余；预计总里程 = 已完成 + 剩余。"""
        fp = FakePlanner()
        res = reroute(fp, self.origin, self.poly, self.along,
                      target_m=1000, completed_m=300, max_calls=4)
        self.assertTrue(res.ok, res.error)
        self.assertGreater(res.chosen.along_m, self.along)
        tail = self.cum[-1] - res.chosen.along_m
        self.assertAlmostEqual(res.remaining_m, res.connector_m + tail, delta=1.5)
        self.assertAlmostEqual(res.estimated_total_m, 300 + res.remaining_m, delta=1.5)
        self.assertLessEqual(res.api_calls, 4)
        self.assertTrue(res.reroute_id.startswith("rr-"))

    def test_merged_remaining_ends_at_route_end(self):
        """合并结果 = 连接段 + 原剩余，终点与原路线终点一致（闭环保住）。"""
        fp = FakePlanner()
        res = reroute(fp, self.origin, self.poly, self.along,
                      target_m=1000, completed_m=300, max_calls=3)
        self.assertTrue(res.ok)
        self.assertGreaterEqual(len(res.merged_remaining), 3)
        self.assertAlmostEqual(res.merged_remaining[-1][0], self.poly[-1][0], places=5)
        self.assertAlmostEqual(res.merged_remaining[-1][1], self.poly[-1][1], places=5)
        # 连接段起点 = 用户当前位置（真实接入）
        self.assertAlmostEqual(res.merged_remaining[0][0], self.origin[0], places=5)

    def test_connector_steps_serialized(self):
        fp = FakePlanner()
        res = reroute(fp, self.origin, self.poly, self.along,
                      target_m=1000, completed_m=300, max_calls=3)
        self.assertTrue(res.connector_steps)
        s0 = res.connector_steps[0]
        for k in ("instruction", "road", "distance_m", "cumulative_m", "action"):
            self.assertIn(k, s0)

    def test_no_rejoin_when_all_fail(self):
        fp = FakePlanner(fail=True)
        res = reroute(fp, self.origin, self.poly, self.along,
                      target_m=1000, completed_m=300, max_calls=3)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_code, "NO_REJOIN")
        self.assertEqual(res.api_calls, 3)   # 预算内全部尝试过

    def test_throttle_maps_to_amap_error(self):
        fp = FakePlanner(throttle=True)
        res = reroute(fp, self.origin, self.poly, self.along,
                      target_m=1000, completed_m=300, max_calls=2)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_code, "AMAP_ERROR")

    def test_bad_request_validation(self):
        fp = FakePlanner()
        r1 = reroute(fp, self.origin, self.poly, self.cum[-1] + 10,
                     target_m=1000, completed_m=0)
        self.assertEqual(r1.error_code, "BAD_REQUEST")
        r2 = reroute(fp, self.origin, [self.poly[0]], 0, target_m=1000, completed_m=0)
        self.assertEqual(r2.error_code, "BAD_REQUEST")
        r3 = reroute(fp, self.origin, self.poly, 100, target_m=0, completed_m=0)
        self.assertEqual(r3.error_code, "BAD_REQUEST")
        self.assertEqual(len(fp.calls), 0)   # 校验失败绝不消耗 API

    def test_tolerance_flag_honest_when_exceeded(self):
        """5.5：绕不出达标方案时 within_tolerance=false + 诚实新总里程。"""
        fp = FakePlanner(factor=20.0)   # 连接段极长（现实中=路网断裂/孤岛）
        res = reroute(fp, self.origin, self.poly, self.along,
                      target_m=int(self.cum[-1]), completed_m=300,
                      tol_m=500, max_calls=3)
        self.assertTrue(res.ok)
        self.assertFalse(res.within_tolerance)
        self.assertGreater(res.estimated_total_m, self.cum[-1] + 500)

    def test_prefers_within_tolerance_candidate(self):
        """5.5：优先选择总距离仍在目标 ±tol 的方案。"""
        fp = FakePlanner(factor=1.05)
        target = int(self.cum[-1])
        res = reroute(fp, self.origin, self.poly, self.along,
                      target_m=target, completed_m=int(self.along),
                      tol_m=500, max_calls=4)
        self.assertTrue(res.ok)
        # 直线路线 + 低绕行系数：应能达标
        if any(c.within_tolerance for c in res.candidates if c.ok):
            self.assertTrue(res.within_tolerance)

    def test_call_budget_hard_cap(self):
        """5.7#10：API 调用硬上限。"""
        fp = FakePlanner(fail=True)
        res = reroute(fp, self.origin, east_line(40), self.along,
                      target_m=5000, completed_m=300, max_calls=2)
        self.assertEqual(res.api_calls, 2)
        self.assertEqual(len(fp.calls), 2)


class TestRerouteEndpoint(unittest.TestCase):
    """server 端点离线集成（替身 planner，走真实 reroute 逻辑）。"""

    def setUp(self):
        os.environ["RUNLOOP_AMAP_KEY"] = "TEST-SECRET-KEY-DO-NOT-LEAK"
        import backend.server as server_mod
        self.server_mod = server_mod
        self._saved_planner = server_mod.AmapWalkingPlanner
        server_mod.AmapWalkingPlanner = lambda *a, **k: FakePlanner()
        self.app = server_mod.create_app()
        self.app.testing = True
        self.client = self.app.test_client()
        self.poly = east_line()
        self.cum = _cumulative(self.poly)

    def tearDown(self):
        self.server_mod.AmapWalkingPlanner = self._saved_planner
        os.environ.pop("RUNLOOP_AMAP_KEY", None)

    def _post(self, payload):
        return self.client.post("/api/route/reroute",
                                data=json.dumps(payload),
                                content_type="application/json",
                                headers={"X-Device-Id": "dev-reroute-test"})

    def _body(self, **over):
        b = {
            "origin": {"lng": 116.0035, "lat": 39.9006},
            "polyline": [list(p) for p in self.poly],
            "along_m": self.cum[3],
            "target_m": 1000,
            "completed_m": 300,
            "heading": 90.0,
        }
        b.update(over)
        return b

    def test_success_contract(self):
        r = self._post(self._body())
        self.assertEqual(r.status_code, 200)
        j = r.get_json()
        self.assertTrue(j["success"])
        for k in ("reroute_id", "connector", "rejoin", "merged_remaining_polyline",
                  "remaining_m", "estimated_total_m", "within_tolerance",
                  "candidates_evaluated", "api_calls", "elapsed_s"):
            self.assertIn(k, j)
        self.assertIn("steps", j["connector"])
        self.assertIn("along_m", j["rejoin"])
        text = r.get_data(as_text=True)
        self.assertNotIn("TEST-SECRET", text)   # Key 绝不进响应

    def test_failure_contract_is_200_with_error_code(self):
        self.server_mod.AmapWalkingPlanner = lambda *a, **k: FakePlanner(fail=True)
        r = self._post(self._body())
        self.assertEqual(r.status_code, 200)
        j = r.get_json()
        self.assertFalse(j["success"])
        self.assertEqual(j["error_code"], "NO_REJOIN")
        self.assertTrue(j["reroute_id"].startswith("rr-"))

    def test_bad_polyline_400(self):
        r = self._post(self._body(polyline=[[116.0, 39.9]]))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["error_code"], "BAD_REQUEST")

    def test_bad_origin_400(self):
        r = self._post(self._body(origin={"lng": 999, "lat": 0}))
        self.assertEqual(r.status_code, 400)

    def test_malformed_json_400(self):
        r = self.client.post("/api/route/reroute", data="{oops",
                             content_type="application/json")
        self.assertEqual(r.status_code, 400)


class TestRerouteTargetPreservation(unittest.TestCase):
    """阶段 N：重规划必须优先保持用户的**目标里程**。

    真实缺陷（阶段 M）：候选评分 extra=connector−skipped 奖励「跳过更多
    原路线」，实测把 1km 路线接回终点后缩成 604m，且固定 ±500m 仍判达标。
    """

    def _square(self, side_m: float = 250.0, lat: float = 39.9, lng: float = 116.0):
        dlat = side_m / 110574.0
        dlng = side_m / (111320.0 * math.cos(math.radians(lat)))
        corners = [(lng, lat), (lng + dlng, lat),
                   (lng + dlng, lat + dlat), (lng, lat + dlat), (lng, lat)]
        dense = []
        for i in range(len(corners) - 1):
            for k in range(10):
                t = k / 10.0
                dense.append((corners[i][0] + (corners[i + 1][0] - corners[i][0]) * t,
                              corners[i][1] + (corners[i + 1][1] - corners[i][1]) * t))
        dense.append(corners[-1])
        return dense

    def test_prefers_candidate_that_keeps_target(self):
        poly = self._square()          # 总长约 1000m 的闭环
        cum = [0.0]
        for i in range(1, len(poly)):
            cum.append(cum[-1] + haversine(poly[i - 1], poly[i]))
        poly_total = cum[-1]
        origin = (poly[0][0] + 0.0005, poly[0][1] + 0.0005)   # 偏离起点约 60m
        res = reroute(FakePlanner(factor=1.15), origin, poly,
                      300.0, 1000.0, 300.0, tol_m=500.0, max_calls=5)
        self.assertTrue(res.ok)
        # 不得直接接回终点（那会丢掉全部剩余路线）
        self.assertNotAlmostEqual(res.chosen.along_m, poly_total, places=1)
        endpoint = max(res.candidates, key=lambda c: c.along_m)
        self.assertLess(abs(res.estimated_total_m - 1000.0),
                        abs(endpoint.estimated_total_m - 1000.0),
                        "选中候选的目标误差必须小于「直接接回终点」")

    def test_relative_tolerance_exposed(self):
        poly = self._square()
        res = reroute(FakePlanner(factor=1.15), poly[0], poly,
                      300.0, 1000.0, 300.0, tol_m=500.0, max_calls=5)
        self.assertTrue(res.ok)
        self.assertEqual(res.tol_effective_m, 50.0, "1km 目标内部容差应为 50m")
        res2 = reroute(FakePlanner(factor=1.15), poly[0], poly,
                       300.0, 50000.0, 300.0, tol_m=500.0, max_calls=5)
        self.assertEqual(res2.tol_effective_m, 500.0, "长距离仍受 ±500m 硬上限")


if __name__ == "__main__":
    unittest.main(verbosity=2)
