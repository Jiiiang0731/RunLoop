#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scorer 模块单元测试。"""
import unittest

from backend.route_generator import (
    closure_score, distance_error_score, repetition_ratio, repetition_score, score_route,
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
        # A->B->C->B->A 折返，重复约 50%
        A = (121.0, 31.0)
        B = (121.0, 31.005)
        C = (121.005, 31.005)
        r = repetition_ratio([A, B, C, B, A])
        self.assertGreater(r, 0.3)
        self.assertLess(r, 0.7)

    def test_repetition_clean_loop(self):
        # 正方形闭环，几乎无重复
        A = (121.0, 31.0)
        B = (121.0, 31.005)
        C = (121.005, 31.005)
        D = (121.005, 31.0)
        r = repetition_ratio([A, B, C, D, A])
        self.assertLess(r, 0.2)

    def test_score_route(self):
        loop = LoopRoute(
            distance_m=15000, duration_s=12000, closure_m=1.0, start_snap_m=10.0,
            polyline=[(121.0, 31.0), (121.0, 31.005), (121.005, 31.005), (121.005, 31.0), (121.0, 31.0)],
            segments=[],
        )
        res = score_route(15000, loop)
        self.assertGreaterEqual(res.total, 0)
        self.assertLessEqual(res.total, 100)
        self.assertIn("park_greenway", res.unavailable)
        self.assertIn("road_safety", res.unavailable)


if __name__ == "__main__":
    unittest.main()
