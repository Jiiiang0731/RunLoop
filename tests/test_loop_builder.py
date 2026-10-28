#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""loop_builder 模块单元测试（用 MockPlanner，不联网）。"""
import unittest

from backend.route_generator import MockPlanner, build_loop, generate_ring
from backend.route_generator.types import PlanResult


class FailingPlanner:
    def __init__(self, msg="no route"):
        self.msg = msg

    def plan_walking(self, origin, dest):
        return PlanResult(error=self.msg)


class TestBuildLoop(unittest.TestCase):
    center = (121.5, 31.2)

    def test_success(self):
        wps = generate_ring(self.center, 1000, 6, 7)
        loop, calls = build_loop(MockPlanner(factor=1.4), self.center, wps)
        self.assertTrue(loop.ok)
        self.assertLess(loop.closure_m, 0.5)
        self.assertEqual(len(loop.segments), 7)  # 6 边 + 1 闭合
        self.assertEqual(calls, 7)
        self.assertAlmostEqual(loop.distance_m, sum(s.distance_m for s in loop.segments), places=6)
        self.assertGreater(loop.distance_m, 0)

    def test_failure(self):
        wps = generate_ring(self.center, 1000, 6, 7)
        loop, calls = build_loop(FailingPlanner(), self.center, wps)
        self.assertFalse(loop.ok)
        self.assertIn("no route", loop.error)
        self.assertEqual(calls, 1)


if __name__ == "__main__":
    unittest.main()
