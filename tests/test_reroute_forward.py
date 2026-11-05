#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 Q 前向偏航重规划测试（A–H，全部离线替身，不触真实 API）。

核心断言：
1. 新路线从当前真实位置出发；
2. 第一段沿当前可靠移动方向，不立即掉头；
3. 不接回已经跑过的路线/身后最近点；
4. 剩余距离 = 已完成 + 连接段 + 原路线剩余；
5. 新 steps 重建、合并终点保持原路线终点；
6. 方向不可靠/无前方接回/剩余过短都如实报错，绝不静默掉头。
"""
import math
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.reroute import (
    _connector_metrics, _cumulative, _project_origin, _recent_points_heading,
    pick_rejoin_candidates, reroute,
)
from backend.route_generator.geo import haversine
from backend.route_generator.types import PlanResult, PlanStep

ROUTE_LAT = 39.9
ROUTE_LNG0 = 116.0
ROUTE_END_LNG = 116.011
ORIGIN = (116.0045, 39.9006)
MLAT = 110574.0
MLNG = 111320.0 * math.cos(math.radians(ROUTE_LAT))


def east_line(n=12):
    return [(ROUTE_LNG0 + i * 0.001, ROUTE_LAT) for i in range(n)]


class ForwardFakePlanner:
    """确定性替身：首段方向可配置，用于验证前向约束。"""

    def __init__(self, fail_mid=False, force_west=False):
        self.fail_mid = fail_mid
        self.force_west = force_west
        self.calls = []

    def plan_walking(self, origin, destination):
        self.calls.append((origin, destination))
        # 让“从偏航位置直接接回原路线”的请求失败，迫使走前向替代路线；
        # 替代路线的前进点已离开原路线（lat 更高），其到终点的第二段可达。
        if (self.fail_mid
                and abs(destination[1] - ROUTE_LAT) < 1e-9
                and origin[0] < 116.0055):
            return PlanResult(error="NO_PATH")
        if self.force_west:
            p1 = (origin[0] - 30.0 / MLNG, origin[1])
        elif destination[0] >= origin[0]:
            p1 = (origin[0] + 25.0 / MLNG, origin[1])
        else:
            # 自然转弯：先向北，再折向目的地（不是立即掉头）
            p1 = (origin[0], origin[1] + 25.0 / MLAT)
        pts = [origin, p1, destination]
        dist = haversine(origin, p1) + haversine(p1, destination)
        step = PlanStep(instruction="直行", road="测试路", distance_m=dist,
                        action="", polyline=pts)
        return PlanResult(distance_m=dist, duration_s=dist / 1.2,
                          points=pts, steps=[step])


class TestHelpers(unittest.TestCase):
    def test_connector_forward_and_backtrack(self):
        o = (116.0, 39.9)
        forward = [(116.0, 39.9), (116.0 + 30 / MLNG, 39.9),
                   (116.0 + 80 / MLNG, 39.9)]
        a, g, b, ok = _connector_metrics(forward, o, 90.0, 10.0, 25.0, 90.0)
        self.assertLess(a, 5.0)
        self.assertGreaterEqual(g, 10.0)
        self.assertLessEqual(b, 1.0)
        self.assertTrue(ok)

        back = [(116.0, 39.9), (116.0 - 30 / MLNG, 39.9),
                (116.0 - 60 / MLNG, 39.9)]
        a2, g2, b2, ok2 = _connector_metrics(back, o, 90.0, 10.0, 25.0, 90.0)
        self.assertGreater(a2, 150.0)
        self.assertGreater(b2, 25.0)
        self.assertFalse(ok2)

    def test_recent_points_heading(self):
        now = int(time.time() * 1000)
        pts = [
            [116.0040, 39.9000, 5, 3.0, now - 8000],
            [116.0045, 39.9000, 6, 3.1, now - 4000],
            [116.0050, 39.9000, 5, 3.2, now],
        ]
        h, src, conf, age = _recent_points_heading(pts)
        self.assertAlmostEqual(h, 90.0, delta=3.0)
        self.assertEqual(src, "recent_points")
        self.assertGreaterEqual(conf, 0.5)
        self.assertLessEqual(age, 1000)

    def test_forward_sampling_filters_opposite_tangent(self):
        out = east_line(8)                       # 向东
        back = [(116.007 - i * 0.001, 39.9005) for i in range(1, 8)]  # 向西返程
        poly = out + back
        cum = _cumulative(poly)
        cands = pick_rejoin_candidates(
            poly, cum, cum[2], 90.0, budget=6, forward_only=True,
            actual_along_m=cum[2], min_forward_gain_m=10,
            max_initial_angle_deg=90)
        self.assertTrue(cands)
        for c in cands:
            self.assertGreaterEqual(c.along_m, cum[2] + 9.9)
            self.assertLessEqual(
                abs((c.tangent or 0.0) - 90.0) % 360.0, 90.0 + 1e-6)


class TestForwardReroute(unittest.TestCase):
    def setUp(self):
        self.poly = east_line()
        self.cum = _cumulative(self.poly)
        self.along = self.cum[4]
        self.total = self.cum[-1]

    def _call(self, planner, **over):
        kw = dict(
            origin=ORIGIN,
            heading=90.0,
            heading_source="gps",
            heading_confidence=0.9,
            forward_only=True,
            tol_m=500,
            max_calls=5,
            min_forward_gain_m=10,
            max_backtrack_m=25,
        )
        kw.update(over)
        origin = kw.pop("origin")
        return reroute(planner, origin, self.poly, self.along,
                       target_m=900, completed_m=300, **kw)

    def test_A_forward_rejoin_starts_at_origin_and_goes_forward(self):
        res = self._call(ForwardFakePlanner())
        self.assertTrue(res.ok, res.error)
        self.assertEqual(res.strategy, "forward_rejoin")
        self.assertGreater(res.actual_along_m, self.along)  # 真实投影，不是旧 along
        self.assertIsNotNone(res.chosen)
        self.assertGreater(res.chosen.along_m, res.actual_along_m + 10)
        self.assertLessEqual(res.chosen.initial_angle_deg, 90.0)
        self.assertLessEqual(res.chosen.backtrack_m, 25.0)
        self.assertGreaterEqual(res.chosen.forward_gain_m, 10.0)
        # 从当前位置出发、终点仍是原路线终点
        self.assertLess(haversine(res.merged_remaining[0], ORIGIN), 30.0)
        self.assertLess(haversine(res.merged_remaining[-1], self.poly[-1]), 30.0)
        # 剩余/预计总里程诚实
        tail = self.total - res.chosen.along_m
        self.assertAlmostEqual(res.remaining_m, res.connector_m + tail, delta=2.0)
        self.assertAlmostEqual(res.estimated_total_m, 300 + res.remaining_m, delta=2.0)
        self.assertTrue(res.connector_steps)
        # 连接段最后一步只是“接回点”，不得提前标记为整条路线终点
        self.assertNotEqual(res.connector_steps[-1]["action"], "end")

    def test_B_no_behind_or_history_rejoin(self):
        res = self._call(ForwardFakePlanner())
        self.assertTrue(res.ok, res.error)
        for c in res.candidates:
            self.assertGreaterEqual(c.along_m, res.actual_along_m + 9.9)

    def test_C_backtracking_connector_is_rejected(self):
        res = self._call(ForwardFakePlanner(force_west=True))
        self.assertFalse(res.ok)
        self.assertEqual(res.error_code, "NO_FORWARD_REJOIN")
        self.assertEqual(res.strategy, "forward")
        self.assertIsNone(res.chosen)
        self.assertTrue(any(c.ok and not c.forward_ok for c in res.candidates))

    def test_D_multiple_candidates_prefer_forward(self):
        # 所有候选都可规划，但只有前向的会被选中；首个候选的连接段是反向时
        # 也不能因为“最近”被选中。
        class FirstBackThenForward(ForwardFakePlanner):
            def __init__(self):
                super().__init__()
                self.n = 0

            def plan_walking(self, origin, destination):
                self.n += 1
                if self.n == 1:
                    # 第一个候选：故意先向西 40m（反向），应被拒绝
                    p1 = (origin[0] - 40.0 / MLNG, origin[1])
                    pts = [origin, p1, destination]
                    dist = haversine(origin, p1) + haversine(p1, destination)
                    return PlanResult(distance_m=dist, duration_s=dist,
                                      points=pts,
                                      steps=[PlanStep(polyline=pts, action="",
                                                      distance_m=dist)])
                return super().plan_walking(origin, destination)

        res = self._call(FirstBackThenForward())
        self.assertTrue(res.ok, res.error)
        self.assertTrue(res.chosen.forward_ok)
        self.assertLessEqual(res.chosen.initial_angle_deg, 90.0)
        self.assertLessEqual(res.chosen.backtrack_m, 25.0)

    def test_E_heading_unreliable_reports(self):
        res = self._call(ForwardFakePlanner(), heading=None,
                         heading_source="none", heading_confidence=0.0)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_code, "HEADING_UNRELIABLE")
        self.assertEqual(res.strategy, "forward")

    def test_F_recent_points_can_recover_heading(self):
        now = int(time.time() * 1000)
        recent = [
            [116.0040, 39.9000, 5, 3.0, now - 8000],
            [116.0045, 39.9000, 5, 3.0, now - 4000],
            [116.0050, 39.9000, 5, 3.0, now],
        ]
        res = self._call(ForwardFakePlanner(), heading=None,
                         heading_source="none", heading_confidence=0.0,
                         recent_points=recent)
        self.assertTrue(res.ok, res.error)
        self.assertEqual(res.heading_source, "recent_points")
        self.assertAlmostEqual(res.heading_used, 90.0, delta=5.0)

    def test_G_short_remaining_distance_reports(self):
        res = reroute(ForwardFakePlanner(), ORIGIN, self.poly, self.along,
                      target_m=1000, completed_m=980, forward_only=True,
                      heading=90.0, heading_source="gps",
                      heading_confidence=0.9, max_calls=4)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_code, "REMAINING_DISTANCE_INFEASIBLE")

    def test_H_consecutive_reroutes_no_state_leak(self):
        p = ForwardFakePlanner()
        r1 = self._call(p)
        origin2 = (116.0055, 39.9006)
        r2 = self._call(p, origin=origin2)
        self.assertTrue(r1.ok and r2.ok)
        self.assertNotEqual(r1.reroute_id, r2.reroute_id)
        self.assertLess(haversine(r1.merged_remaining[0], ORIGIN), 30.0)
        self.assertLess(haversine(r2.merged_remaining[0], origin2), 30.0)
        self.assertGreater(r2.actual_along_m, r1.actual_along_m)

    def test_stale_request_reports(self):
        res = self._call(ForwardFakePlanner(),
                         sent_at_ms=time.time() * 1000 - 60000)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_code, "STALE_REQUEST")

    def test_fallback_forward_loop_when_no_rejoin(self):
        # 原路线中段接回点全部不可达；前向替代路线仍可生成
        res = self._call(ForwardFakePlanner(fail_mid=True), max_calls=5)
        self.assertTrue(res.ok, res.error)
        self.assertEqual(res.strategy, "forward_loop")
        self.assertLess(haversine(res.merged_remaining[0], ORIGIN), 30.0)
        self.assertLess(haversine(res.merged_remaining[-1], self.poly[-1]), 30.0)
        self.assertLessEqual(res.chosen.initial_angle_deg, 90.0)
        self.assertAlmostEqual(res.estimated_total_m,
                               300 + res.remaining_m, delta=2.0)
        # 前向替代路线真正回到原终点，最后一步保留 end
        self.assertEqual(res.connector_steps[-1]["action"], "end")

    def test_legacy_path_unchanged(self):
        res = reroute(ForwardFakePlanner(), ORIGIN, self.poly, self.along,
                      target_m=900, completed_m=300, heading=90.0,
                      forward_only=False, max_calls=3)
        self.assertTrue(res.ok, res.error)
        self.assertEqual(res.strategy, "legacy")


if __name__ == "__main__":
    unittest.main()
