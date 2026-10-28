#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""control_points 模块单元测试。"""
import unittest

from backend.route_generator import generate_ring, haversine


class TestGenerateRing(unittest.TestCase):
    center = (121.5, 31.2)

    def test_count(self):
        self.assertEqual(len(generate_ring(self.center, 1000, 8, 42)), 8)

    def test_determinism(self):
        self.assertEqual(generate_ring(self.center, 1000, 8, 42),
                         generate_ring(self.center, 1000, 8, 42))

    def test_seed_changes_points(self):
        self.assertNotEqual(generate_ring(self.center, 1000, 8, 42),
                            generate_ring(self.center, 1000, 8, 43))

    def test_radius_bounds(self):
        pts = generate_ring(self.center, 1000, 16, 7, jitter=0.15)
        for p in pts:
            d = haversine(self.center, p)
            self.assertGreaterEqual(d, 840)
            self.assertLessEqual(d, 1160)


if __name__ == "__main__":
    unittest.main()
