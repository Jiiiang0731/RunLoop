#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""generator 编排层单元测试（用 MockPlanner，不联网）。"""
import unittest

from backend.route_generator import GenerateOptions, MockPlanner, generate_candidates
from backend.route_generator.types import PlanResult


class AlwaysFailPlanner:
    def plan_walking(self, origin, dest):
        return PlanResult(error="no route")


class TestGenerator(unittest.TestCase):
    center = (121.5, 31.2)

    def test_two_candidates(self):
        opts = GenerateOptions(target_m=10000, seeds=[1, 2], n_points=8,
                               tol_m=500, max_iters=8, detour_factor=1.4, sleep_s=0)
        res = generate_candidates(MockPlanner(factor=1.4), self.center, opts)
        self.assertEqual(len(res.candidates), 2)
        for c in res.candidates:
            self.assertIsNotNone(c.loop)
            self.assertTrue(c.loop.ok)
            self.assertIsNotNone(c.score)
            self.assertIsNone(c.error)
        self.assertGreater(res.total_api_calls, 0)

    def test_failure_propagates(self):
        opts = GenerateOptions(target_m=10000, seeds=[1], n_points=8,
                               max_iters=3, detour_factor=1.4, sleep_s=0)
        res = generate_candidates(AlwaysFailPlanner(), self.center, opts)
        self.assertEqual(len(res.candidates), 1)
        self.assertIsNotNone(res.candidates[0].error)
        self.assertIsNone(res.candidates[0].score)


if __name__ == "__main__":
    unittest.main()
