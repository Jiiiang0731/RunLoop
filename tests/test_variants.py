#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""variants 模块单元测试（纯逻辑，不联网）。"""
import unittest

from backend.route_generator import SkeletonVariant, plan_variants
from backend.route_generator.variants import lean_n_points


class TestLeanNPoints(unittest.TestCase):
    def test_calibrated_values(self):
        # 实测标定：15km(base 9)→6、20km(base 10)→6、10km(base 6)→5、5km(base 5)→5
        self.assertEqual(lean_n_points(9), 6)
        self.assertEqual(lean_n_points(10), 6)
        self.assertEqual(lean_n_points(6), 5)
        self.assertEqual(lean_n_points(5), 5)

    def test_floor(self):
        self.assertGreaterEqual(lean_n_points(3), 5)


class TestPlanVariants(unittest.TestCase):
    def test_order_lean_ell_first_then_base(self):
        vs = plan_variants(15000, 9, 2)
        self.assertEqual([v.label for v in vs], ["lean_ell", "base", "lean_cir"])
        # base 与旧基线一致（点数/圆形/抖动/迭代预算）
        self.assertEqual(vs[1].n_points, 9)
        self.assertEqual(vs[1].aspect, 1.0)
        self.assertEqual(vs[1].angle_deg, 0.0)
        self.assertEqual(vs[1].jitter, 0.15)
        self.assertEqual(vs[1].max_iters, 8)

    def test_lean_variants_have_fewer_points(self):
        vs = plan_variants(15000, 9, 2)
        self.assertEqual(vs[0].n_points, 6)   # 15km 实测最优
        self.assertEqual(vs[2].n_points, 6)
        self.assertEqual(vs[0].aspect, 1.5)   # 椭圆：两条长直边
        self.assertEqual(vs[2].aspect, 1.3)   # 低抖动椭圆（多样性兜底）
        self.assertLess(vs[0].jitter, vs[1].jitter)
        self.assertLess(vs[2].jitter, vs[1].jitter)
        # lean 变体迭代预算更小（控制失败时的调用浪费）
        self.assertLess(vs[0].max_iters, vs[1].max_iters)

    def test_short_distance_base_only(self):
        """5km base 已是 5 点：减点无意义 → 仅返回 base（省调用）。"""
        vs = plan_variants(5000, 5, 3)
        self.assertEqual(len(vs), 1)
        self.assertEqual(vs[0].label, "base")

    def test_deterministic(self):
        a = plan_variants(10000, 6, 7)
        b = plan_variants(10000, 6, 7)
        self.assertEqual(a, b)

    def test_seed_changes_angles(self):
        a = plan_variants(15000, 9, 1)
        b = plan_variants(15000, 9, 2)
        self.assertNotEqual(a[0].angle_deg, b[0].angle_deg)
        # 同一 seed 的两个 lean 变体方向差异 ≥60°
        diff = abs(a[0].angle_deg - a[2].angle_deg)
        self.assertGreaterEqual(min(diff, 360 - diff), 60)

    def test_min_points_floor(self):
        vs = plan_variants(7000, 6, 3)
        for v in vs:
            self.assertGreaterEqual(v.n_points, 5)

    def test_custom_base_jitter_and_iters(self):
        vs = plan_variants(10000, 6, 1, base_jitter=0.2, base_max_iters=4)
        self.assertEqual(vs[1].jitter, 0.2)
        self.assertEqual(vs[1].max_iters, 4)

    def test_variant_is_frozen(self):
        v = SkeletonVariant(6, 1.5, 30.0, 0.1, 5, "x")
        with self.assertRaises(Exception):
            v.n_points = 7  # type: ignore[misc]


class TestShortDistanceGrid(unittest.TestCase):
    """阶段 N：≤3km 用「半径×形状」确定性网格，取代会振荡的 R 定点迭代。"""

    def test_grid_variants_single_build(self):
        vs = plan_variants(1000, 8, 1)
        self.assertGreaterEqual(len(vs), 4)
        for v in vs:
            self.assertEqual(v.max_iters, 1, "网格变体只建一次，不做 R 迭代")
            self.assertGreaterEqual(v.n_points, 8, "街区尺度需要足够控制点")
        # 形状覆盖矩形与圆（城市街区更接近矩形）
        shapes = {v.shape for v in vs}
        self.assertIn("rect", shapes)
        self.assertIn("ring", shapes)
        # 偏移中心变体：覆盖「起点在环线一角」的自然环线（阶段 N 关键修复）
        offsets = [v for v in vs if v.offset_factor > 0 and v.offset_dir_deg >= 0]
        self.assertGreaterEqual(len(offsets), 2, "需要多个偏移方位的候选")
        dirs = {v.offset_dir_deg for v in offsets}
        self.assertGreaterEqual(len(dirs), 2)
        # 半径倍率：至少有一个放大变体 + 基准变体
        factors = sorted(v.radius_factor for v in vs)
        self.assertEqual(factors[0], 1.0)
        self.assertGreater(factors[-1], 1.2)

    def test_medium_distance_keeps_legacy_variants(self):
        vs = plan_variants(5000, 5, 3)
        self.assertEqual([v.label for v in vs], ["base"])

    def test_grid_deterministic(self):
        self.assertEqual(plan_variants(2500, 8, 4), plan_variants(2500, 8, 4))


if __name__ == "__main__":
    unittest.main()
