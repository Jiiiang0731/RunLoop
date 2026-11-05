#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""control_points 模块单元测试。"""
import math
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

    def test_start_on_ring_eliminates_lollipop(self):
        """P1：中心偏移 R + 首点对准起点 → 起点就在环线上。"""
        start = (121.5, 31.2)
        R = 200.0
        for dir_deg in (45.0, 135.0, 225.0, 315.0):
            brg = math.radians(dir_deg)
            center = (start[0] + math.sin(brg) * R / (111320.0 * math.cos(math.radians(start[1]))),
                      start[1] + math.cos(brg) * R / 110574.0)
            pts = generate_ring(center, R, 8, 1, jitter=0.0,
                                base_angle_deg=(270.0 - dir_deg) % 360.0)
            # 第一个点在起点附近（≤2m），闭环不再有径向棒棒糖尾巴
            self.assertLess(haversine(start, pts[0]), 2.0, f"dir={dir_deg}")


if __name__ == "__main__":
    unittest.main()
