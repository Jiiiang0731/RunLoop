#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""anchor_loop 单测：锚点闭环走真实规划、裁剪只去拐点、失败如实上报。"""
import unittest

from backend.route_generator.anchor_loop import build_anchor_loop
from backend.route_generator.geo import haversine
from backend.route_generator.types import PlanResult, PlanStep


class FakePlanner:
    def __init__(self, factor=1.15, fail=False):
        self.factor = factor
        self.fail = fail
        self.calls = 0

    def plan_walking(self, o, d):
        self.calls += 1
        if self.fail:
            return PlanResult(error="NO_PATH")
        dist = haversine(o, d) * self.factor
        pts = [o, ((o[0] + d[0]) / 2, (o[1] + d[1]) / 2), d]
        return PlanResult(distance_m=dist, duration_s=dist / 1.2, points=pts,
                          steps=[PlanStep(instruction="直行", road="测试路",
                                          distance_m=dist, polyline=pts)])


def square(side_m=600.0, lat=30.535, lng=114.0275):
    dlat = side_m / 110574.0
    dlng = side_m / (111320.0 * __import__("math").cos(__import__("math").radians(lat)))
    return [(lng, lat), (lng + dlng, lat),
            (lng + dlng, lat + dlat), (lng, lat + dlat)]


class OpenAtClosePlanner(FakePlanner):
    """闭合段故意把终点甩开 120m：模拟「为了凑距离切断闭环」。"""

    def __init__(self, close_point, **kw):
        super().__init__(**kw)
        self.close_point = close_point

    def plan_walking(self, o, d):
        r = super().plan_walking(o, d)
        if d == self.close_point and o != self.close_point:
            off = (d[0] + 0.0012, d[1])
            r.points = [o, ((o[0] + off[0]) / 2, (o[1] + off[1]) / 2), off]
            r.steps[0].polyline = r.points
        return r


class TestAnchorLoop(unittest.TestCase):
    def test_builds_loop_through_each_anchor(self):
        pl = FakePlanner()
        r = build_anchor_loop(pl, square(500.0), 2300, tol_m=500)
        self.assertIsNotNone(r["loop"])
        # 10 段（4 锚点 + 闭合）每段都要真实规划，绝不直线连
        self.assertGreaterEqual(pl.calls, 4)
        self.assertAlmostEqual(r["loop"].distance_m, 2000 * 1.15, delta=10.0)

    def test_trim_drops_anchor_to_reach_target(self):
        pl = FakePlanner()
        # 方环周长 2000m×1.15=2300m；目标 1500m 时需裁剪
        r = build_anchor_loop(pl, square(500.0), 1500, tol_m=500)
        self.assertTrue(r["ok"], r)
        self.assertGreaterEqual(r["best"]["drop"], 0)
        self.assertLessEqual(abs(r["best"]["err"]), 500)

    def test_unreachable_reports_error(self):
        r = build_anchor_loop(FakePlanner(fail=True), square(400.0), 2000)
        self.assertFalse(r["ok"])
        self.assertIn("不可达", r["error"])

    def test_too_few_anchors(self):
        r = build_anchor_loop(FakePlanner(), [(114.0, 30.5), (114.001, 30.5)], 1000)
        self.assertFalse(r["ok"])

    def test_crop_never_breaks_closure_or_truncates_polyline(self):
        """裁剪只能「去拐点后重新规划闭合」，不能切割折线；候选必须闭合。"""
        anchors = square(600.0)
        r = build_anchor_loop(FakePlanner(factor=1.25), anchors, 2500, tol_m=500)
        self.assertTrue(r["ok"])
        self.assertGreaterEqual(r["best"]["drop"], 1, "2.5km 应由裁剪命中")
        for c in r["candidates"]:
            self.assertTrue(c["closure_ok"], c)
            self.assertLessEqual(c["closure_m"], 50.0, c)
            self.assertNotEqual(c["drop"], 0, "首锚点是起点，任何裁剪都不得丢掉")
        loop = r["loop"]
        self.assertAlmostEqual(
            loop.distance_m,
            sum(seg.distance_m for seg in loop.segments), delta=0.01)
        self.assertLessEqual(loop.closure_m, 50.0)

    def test_open_closure_is_rejected_not_patched(self):
        anchors = square(450.0)
        r = build_anchor_loop(OpenAtClosePlanner(anchors[0]), anchors, 1800)
        self.assertFalse(r["ok"])
        self.assertIsNone(r["loop"])
        self.assertIn("闭合", r["error"])

    def test_candidate_details_report_closure_and_score(self):
        r = build_anchor_loop(FakePlanner(), square(500.0), 2300, tol_m=500)
        self.assertTrue(r["ok"])
        for c in r["candidates"]:
            self.assertIn("closure_m", c)
            self.assertIn("score", c)
            self.assertTrue(c["closure_ok"])


if __name__ == "__main__":
    unittest.main()
