#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scorer 模块单元测试（阶段 I 五维评分）。"""
import unittest

from backend.route_generator import (
    closure_score, distance_error_score, repetition_ratio, repetition_score, score_route,
    turn_density_score, long_straight_score, sharp_short_score,
)
from backend.route_generator.types import LoopRoute


class TestScores(unittest.TestCase):
    def test_distance_error(self):
        self.assertEqual(distance_error_score(0), 100.0)
        self.assertEqual(distance_error_score(300), 100.0)
        self.assertEqual(distance_error_score(-300), 100.0)
        self.assertEqual(distance_error_score(800), 75.0)
        self.assertEqual(distance_error_score(2300), 0.0)
        self.assertEqual(distance_error_score(5000), 0.0)

    def test_closure(self):
        self.assertEqual(closure_score(0), 100.0)
        self.assertEqual(closure_score(5), 100.0)
        self.assertEqual(closure_score(100), 0.0)
        self.assertAlmostEqual(closure_score(50), 52.6, places=1)

    def test_repetition_score(self):
        self.assertEqual(repetition_score(0.0), 100.0)
        self.assertEqual(repetition_score(0.5), 0.0)

    def test_repetition_backtrack(self):
        A = (121.0, 31.0)
        B = (121.0, 31.005)
        C = (121.005, 31.005)
        r = repetition_ratio([A, B, C, B, A])
        self.assertGreater(r, 0.3)
        self.assertLess(r, 0.7)

    def test_repetition_clean_loop(self):
        A = (121.0, 31.0)
        B = (121.0, 31.005)
        C = (121.005, 31.005)
        D = (121.005, 31.0)
        r = repetition_ratio([A, B, C, D, A])
        self.assertLess(r, 0.2)

    def test_turn_density_score(self):
        self.assertEqual(turn_density_score(0.3), 100.0)
        self.assertEqual(turn_density_score(2.0), 0.0)
        self.assertLess(turn_density_score(1.5), turn_density_score(0.8))
        self.assertGreater(turn_density_score(0.5), turn_density_score(1.2))

    def test_long_straight_score(self):
        good = {"straight_ratio_300": 0.8, "straight_avg_m": 700}
        bad = {"straight_ratio_300": 0.0, "straight_avg_m": 0}
        self.assertEqual(long_straight_score(good), 100.0)
        self.assertEqual(long_straight_score(bad), 0.0)

    def test_sharp_short_score(self):
        self.assertEqual(sharp_short_score({}), 100.0)
        self.assertLess(sharp_short_score({"sharp_turns": 2, "short_consecutive": 2}),
                        sharp_short_score({"sharp_turns": 0, "short_consecutive": 0}))

    def test_score_route(self):
        loop = LoopRoute(
            distance_m=15000, duration_s=12000, closure_m=1.0, start_snap_m=10.0,
            polyline=[(121.0, 31.0), (121.0, 31.005), (121.005, 31.005), (121.005, 31.0), (121.0, 31.0)],
            segments=[],
        )
        metrics = {
            "turns": 10, "turn_density": 0.7, "sharp_turns": 1, "short_consecutive": 0,
            "uturns": 0, "straight_avg_m": 500, "straight_median_m": 480,
            "straight_max_m": 1200, "straight_ratio_300": 0.55, "repetition_ratio": 0.05,
        }
        res = score_route(15000, loop, metrics)
        self.assertGreaterEqual(res.total, 0)
        self.assertLessEqual(res.total, 100)
        names = [c.name for c in res.components]
        for name in ("turn_density", "long_straight", "repetition", "sharp_short", "distance_fit", "closure"):
            self.assertIn(name, names)
        closure = [c for c in res.components if c.name == "closure"][0]
        self.assertEqual(closure.weight, 0.0, "闭合是硬约束，不应参与加权")

    def test_better_route_scores_higher(self):
        loop = LoopRoute(
            distance_m=15000, duration_s=12000, closure_m=1.0, start_snap_m=10.0,
            polyline=[(121.0, 31.0), (121.0, 31.005), (121.005, 31.005), (121.005, 31.0), (121.0, 31.0)],
            segments=[],
        )
        good = {"turns": 6, "turn_density": 0.5, "sharp_turns": 0, "short_consecutive": 0,
                "uturns": 0, "straight_avg_m": 700, "straight_max_m": 1800,
                "straight_ratio_300": 0.7, "repetition_ratio": 0.01}
        bad = {"turns": 24, "turn_density": 1.8, "sharp_turns": 4, "short_consecutive": 3,
               "uturns": 1, "straight_avg_m": 120, "straight_max_m": 300,
               "straight_ratio_300": 0.05, "repetition_ratio": 0.35}
        self.assertGreater(score_route(15000, loop, good).total,
                           score_route(15000, loop, bad).total)


if __name__ == "__main__":
    unittest.main()
