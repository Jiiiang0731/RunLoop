#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导航文字与重复路段识别的单元测试（合成数据，不联网）。"""
import unittest

from backend.route_generator.nav_text import build_nav_instructions, turn_kind, bearing
from backend.route_generator.overlap import detect_overlaps
from backend.route_generator.sampling import sample_points_by_distance
from backend.route_generator.types import PlanStep


def make_step(points, road, dist):
    return PlanStep(road=road, distance_m=dist, polyline=points)


class TestTurnKind(unittest.TestCase):
    def test_straight(self):
        self.assertEqual(turn_kind(90, 95), "straight")

    def test_left(self):
        # 东(90) -> 北(0)：向左转
        self.assertEqual(turn_kind(90, 0), "left")

    def test_right(self):
        # 北(0) -> 东(90)：向右转
        self.assertEqual(turn_kind(0, 90), "right")

    def test_uturn(self):
        self.assertEqual(turn_kind(0, 180), "uturn")


class TestNavText(unittest.TestCase):
    def test_no_compass_words(self):
        steps = [
            make_step([(0.0, 0.0), (0.001, 0.0), (0.002, 0.0)], "A路", 200),
            make_step([(0.002, 0.0), (0.002, 0.001), (0.002, 0.002)], "B路", 200),
        ]
        nav = build_nav_instructions(steps)
        self.assertTrue(nav)
        for item in nav:
            self.assertNotIn("东", item["text"])
            self.assertNotIn("南", item["text"])
            self.assertNotIn("西", item["text"])
            self.assertNotIn("北", item["text"])
        # 东->北 应为左转
        self.assertEqual(nav[0]["turn"], "left")
        self.assertIn("左转", nav[0]["text"])

    def test_merge_short_straight(self):
        # 中间包含 10 米的直行碎步，应被合并
        steps = [
            make_step([(0.0, 0.0), (0.001, 0.0)], "A路", 100),
            make_step([(0.001, 0.0), (0.0011, 0.0)], "A路", 10),
            make_step([(0.0011, 0.0), (0.0011, 0.001)], "B路", 100),
        ]
        nav = build_nav_instructions(steps)
        self.assertLessEqual(len(nav), 2)

    def test_cumulative_distance_increases(self):
        steps = [
            make_step([(0.0, 0.0), (0.001, 0.0)], "A路", 100),
            make_step([(0.001, 0.0), (0.002, 0.0)], "B路", 50),
        ]
        nav = build_nav_instructions(steps)
        cums = [n["cumulative_m"] for n in nav]
        self.assertEqual(cums, sorted(cums))


class TestOverlap(unittest.TestCase):
    def test_detect_out_and_back(self):
        # 一条直线去程 + 完全反向返程
        pts = [
            (0.0, 0.0), (0.0, 0.001), (0.0, 0.002), (0.0, 0.003),
            (0.0, 0.004), (0.0, 0.003), (0.0, 0.002), (0.0, 0.001),
            (0.0, 0.0),
        ]
        groups = detect_overlaps(pts, index_gap=2, min_edges=2)
        self.assertTrue(groups, "应识别出去程/返程重复")
        self.assertTrue(all(len(g["ranges"]) == 2 for g in groups))

    def test_no_overlap_for_straight_line(self):
        pts = [(0.0, i * 0.001) for i in range(10)]
        groups = detect_overlaps(pts, index_gap=2, min_edges=2)
        self.assertEqual(groups, [])


class TestSampling(unittest.TestCase):
    def test_cumulative_increases(self):
        # 约 1.1km 的直线（每 0.001 经度度 ≈ 111m）
        pts = [(0.0, i * 0.001) for i in range(11)]
        samples = sample_points_by_distance(pts, interval_m=200, max_points=5)
        self.assertTrue(samples)
        cums = [c for _, c in samples]
        self.assertEqual(cums, sorted(cums))
        for c in cums:
            self.assertGreaterEqual(c, 200)

    def test_covers_whole_route(self):
        # 约 5km，应采样到 4km 以上，覆盖中后段
        pts = [(0.0, i * 0.001) for i in range(46)]
        samples = sample_points_by_distance(pts, interval_m=1000, max_points=10)
        self.assertGreaterEqual(max(c for _, c in samples), 4000)

    def test_short_route_fallback(self):
        pts = [(0.0, 0.0), (0.0, 0.001)]
        samples = sample_points_by_distance(pts, interval_m=1000, max_points=5)
        self.assertEqual(len(samples), 1)


if __name__ == "__main__":
    unittest.main()
