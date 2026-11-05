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


if __name__ == "__main__":
    unittest.main()
