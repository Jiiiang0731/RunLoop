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


class TestOverlapV2Pairing(unittest.TestCase):
    """v2 真实空间配对：路口处两条不同道路的去/返不得错配（v1 缺陷）。"""

    @staticmethod
    def _cross_junction_route():
        """X 路向东去 → 路口转 Y 路向北去 → 大环线 → Y 路返回 → X 路返回。

        索引布局：X-out 边 0..9；Y-out 边 10..15；环线 边 16..29；
        Y-back 边 30..35；X-back 边 36..45。
        v1 按「相邻区间两两配对」会错配 (X-out,Y-out) 与 (Y-back,X-back)。
        """
        pts = []
        # X-out: (0,0) → (0.004,0)，10 边
        for k in range(11):
            pts.append((k * 0.0004, 0.0))
        # Y-out: (0.004,0) → (0.004,0.006)，6 边
        for k in range(1, 7):
            pts.append((0.004, k * 0.001))
        # 大环线（远离 X/Y ≥ 40m）：17..30
        loop = [
            (0.006, 0.0065), (0.008, 0.0068), (0.010, 0.0065), (0.0115, 0.0055),
            (0.012, 0.004), (0.0118, 0.0025), (0.011, 0.0015), (0.0095, 0.001),
            (0.008, 0.0012), (0.007, 0.002), (0.0062, 0.003), (0.0055, 0.004),
            (0.0048, 0.005), (0.004, 0.006),
        ]
        pts.extend(loop)
        # Y-back: (0.004,0.006) → (0.004,0)，6 边
        for k in range(5, -1, -1):
            pts.append((0.004, k * 0.001))
        # X-back: (0.004,0) → (0,0)，10 边
        for k in range(9, -1, -1):
            pts.append((k * 0.0004, 0.0))
        return pts

    def test_pairs_by_spatial_correspondence_not_adjacency(self):
        pts = self._cross_junction_route()
        groups = detect_overlaps(pts, index_gap=6, min_edges=3)
        self.assertEqual(len(groups), 2, f"应恰好两组：{groups}")
        # 按 pass1 起点排序：X 组在前（start=0），Y 组在后（start=10）
        gx, gy = groups[0], groups[1]
        self.assertEqual((gx["passes"][0]["start"], gx["passes"][0]["end"]), (0, 10))
        self.assertEqual((gx["passes"][1]["start"], gx["passes"][1]["end"]), (36, 46))
        self.assertEqual((gy["passes"][0]["start"], gy["passes"][0]["end"]), (10, 16))
        self.assertEqual((gy["passes"][1]["start"], gy["passes"][1]["end"]), (30, 36))
        # 绝不允许 v1 式错配：X-out 与 Y-out 同组
        for g in groups:
            starts = {p["start"] for p in g["passes"]}
            self.assertNotEqual(starts, {0, 10}, "路口两条路被错配为一组")

    def test_group_fields_contract(self):
        pts = self._cross_junction_route()
        groups = detect_overlaps(pts, index_gap=6, min_edges=3)
        for g in groups:
            self.assertEqual(g["direction"], "reverse")
            self.assertEqual(len(g["ranges"]), 2)
            self.assertEqual(g["ranges"][0]["offset"], -1.0)
            self.assertEqual(g["ranges"][1]["offset"], 1.0)
            p1, p2 = g["passes"]
            self.assertEqual((p1["pass"], p2["pass"]), (1, 2))
            # 累计里程：严格递增且 pass2 在后
            self.assertLess(p1["cum_start_m"], p1["cum_end_m"])
            self.assertLess(p1["cum_end_m"], p2["cum_start_m"])
            self.assertLess(p2["cum_start_m"], p2["cum_end_m"])
            # ranges 与 passes 点区间一致（v1 兼容层）
            self.assertEqual(g["ranges"][0]["start"], p1["start"])
            self.assertEqual(g["ranges"][0]["end"], p1["end"])
            self.assertEqual(g["ranges"][1]["start"], p2["start"])
            self.assertEqual(g["ranges"][1]["end"], p2["end"])

    def test_same_direction_repeat_marked_forward(self):
        # 同向重复：出去 → 大环 → 同方向再走一遍同一条路
        pts = []
        for k in range(9):                     # X-out 边 0..7（向东）
            pts.append((k * 0.0005, 0.0))
        loop = [(0.006, 0.002), (0.007, 0.004), (0.006, 0.006),
                (0.004, 0.007), (0.002, 0.0065), (0.0005, 0.005),
                (-0.001, 0.003), (-0.0015, 0.001), (-0.001, 0.0)]
        pts.extend(loop)                       # 环线回到 X 路起点西侧
        for k in range(9):                     # 再次向东走 X（同向重复）
            pts.append((-0.001 + k * 0.000625, 0.0))
        groups = detect_overlaps(pts, index_gap=6, min_edges=3)
        # 同向平行（夹角 ≤20°）也应识别，且 direction=forward
        fwd = [g for g in groups if g["direction"] == "forward"]
        self.assertTrue(fwd, f"同向重复未识别：{groups}")


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
