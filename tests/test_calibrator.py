#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""calibrator 模块单元测试（用 MockPlanner，不联网）。"""
import unittest

from backend.route_generator import MockPlanner, calibrate
from backend.route_generator.types import PlanResult


class AlwaysFailPlanner:
    def plan_walking(self, origin, dest):
        return PlanResult(error="no route")


class TestCalibrate(unittest.TestCase):
    center = (121.5, 31.2)

    def test_converges(self):
        cr = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                       tol_m=500, max_iters=8, detour_factor=1.4)
        self.assertIsNotNone(cr.loop)
        self.assertTrue(cr.loop.ok)
        self.assertLessEqual(abs(cr.best_error_m), 500)
        self.assertGreater(cr.api_calls, 0)

    def test_deterministic(self):
        a = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                      tol_m=500, max_iters=8, detour_factor=1.4)
        b = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                      tol_m=500, max_iters=8, detour_factor=1.4)
        self.assertEqual(a.loop.distance_m, b.loop.distance_m)

    def test_all_fail_returns_none(self):
        cr = calibrate(AlwaysFailPlanner(), self.center, 10000, 8, 5,
                       tol_m=500, max_iters=4, detour_factor=1.4)
        self.assertIsNone(cr.loop)
        self.assertGreater(cr.api_calls, 0)
        self.assertEqual(len(cr.history), 4)


if __name__ == "__main__":
    unittest.main()
