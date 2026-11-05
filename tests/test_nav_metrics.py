#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路线质量指标（有效转弯/直行路段）单元测试。"""
import unittest

from backend.route_generator.nav_metrics import analyze_route, detect_turns
from backend.route_generator.types import PlanStep


def _line(p0, p1, n=2):
    pts = []
    for i in range(n):
        t = i / (n - 1)
        pts.append((p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t))
    return pts


class TestNavMetrics(unittest.TestCase):
    def test_turns_and_straight_runs(self):
        east1 = _line((121.0, 31.0), (121.005, 31.0))
        north1 = _line((121.005, 31.0), (121.005, 31.004))
        east2 = _line((121.005, 31.004), (121.010, 31.004))
        steps = [
            PlanStep(road="A", distance_m=482, polyline=east1),
            PlanStep(road="B", distance_m=444, polyline=north1),
            PlanStep(road="C", distance_m=482, polyline=east2),
        ]
        turns = detect_turns(steps)
        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[0]["kind"], "left")
        self.assertEqual(turns[1]["kind"], "right")

        full = east1 + north1[1:] + east2[1:]
        m = analyze_route(steps, full, 1500)
        self.assertEqual(m["turns"], 2)
        self.assertGreater(m["turn_density"], 0)
        self.assertGreater(m["straight_max_m"], 300)
        self.assertEqual(m["straight_ratio_300"], 1.0)

    def test_no_turn_straight(self):
        pts = _line((121.0, 31.0), (121.01, 31.0), 5)
        steps = [PlanStep(road="A", distance_m=964, polyline=pts)]
        m = analyze_route(steps, pts, 1000)
        self.assertEqual(m["turns"], 0)
        self.assertEqual(m["turn_density"], 0.0)
        self.assertEqual(m["sharp_turns"], 0)

    def test_short_consecutive_turns(self):
        # 极短的连续转弯：东 -> 北 -> 东，转弯间距很短
        a = _line((121.0, 31.0), (121.0002, 31.0))
        b = _line((121.0002, 31.0), (121.0002, 31.0002))
        c = _line((121.0002, 31.0002), (121.0004, 31.0002))
        steps = [
            PlanStep(road="A", distance_m=19, polyline=a),
            PlanStep(road="B", distance_m=22, polyline=b),
            PlanStep(road="C", distance_m=19, polyline=c),
        ]
        m = analyze_route(steps, a + b[1:] + c[1:], 100)
        self.assertGreaterEqual(m["short_consecutive"], 1)

    def test_walk_bad_ratio_from_walk_type(self):
        """阶段 N：真实 walk_type 统计——地下通道/天桥等不适合跑步的路段占比。"""
        a = _line((121.0, 31.0), (121.0002, 31.0))        # ~19m 普通道路
        b = _line((121.0002, 31.0), (121.0002, 31.0002))  # ~22m 地下通道
        steps = [
            PlanStep(road="A", distance_m=19, polyline=a, walk_type="0"),
            PlanStep(road="B", distance_m=22, polyline=b, walk_type="3"),
        ]
        m = analyze_route(steps, a + b[1:], 100)
        self.assertAlmostEqual(m["walk_bad_ratio"], 22 / 41, places=2)
        self.assertEqual(m["walk_types"], {"0": 1, "3": 1})

        clean = [PlanStep(road="A", distance_m=19, polyline=a, walk_type="0")]
        self.assertEqual(analyze_route(clean, a, 100)["walk_bad_ratio"], 0.0)

        # 实测未收录取值 20：只上报 unclassified，不猜测、不计入非地面比例
        unknown = [PlanStep(road="A", distance_m=19, polyline=a, walk_type="20")]
        m2 = analyze_route(unknown, a, 100)
        self.assertEqual(m2["walk_bad_ratio"], 0.0)
        self.assertEqual(m2["walk_type_profile"]["unclassified_counts"], {"20": 1})


if __name__ == "__main__":
    unittest.main()
