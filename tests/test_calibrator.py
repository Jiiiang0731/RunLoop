#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""calibrator 模块单元测试（用 MockPlanner/构造 Planner，不联网）。

阶段 J：覆盖「多变体质量选择 + 提前终止 + 预算护栏 + 兼容单变体」。
"""
import unittest

from backend.route_generator import MockPlanner, SkeletonVariant, calibrate, plan_variants
from backend.route_generator.calibrator import _is_better, _should_stop_early
from backend.route_generator.geo import haversine
from backend.route_generator.types import PlanResult, PlanStep


class AlwaysFailPlanner:
    def plan_walking(self, origin, dest):
        return PlanResult(error="no route")


class QualityRiggedPlanner:
    """前 rig_calls 次调用返回「每段 5 个左转子步骤」的低质量结果；
    之后返回纯直行（高质量）。距离与 MockPlanner 完全一致（R 收敛轨迹相同）。
    """

    def __init__(self, factor: float = 1.4, n_samples: int = 12, rig_calls: int = 0):
        self.factor = factor
        self.n_samples = n_samples
        self.rig_calls = rig_calls
        self.calls = 0

    @property
    def http_calls(self) -> int:
        return self.calls

    def plan_walking(self, origin, dest):
        self.calls += 1
        straight = haversine(origin, dest)
        pts = []
        for k in range(self.n_samples + 1):
            t = k / self.n_samples
            pts.append((origin[0] + (dest[0] - origin[0]) * t,
                        origin[1] + (dest[1] - origin[1]) * t))
        distance = straight * self.factor
        if self.calls <= self.rig_calls:
            # 低质量：5 个「左转」子步骤（真实转弯统计会数出 5 次/段）
            per = distance / 5.0
            steps = []
            for j in range(5):
                lo = (self.n_samples * j) // 5
                hi = (self.n_samples * (j + 1)) // 5
                steps.append(PlanStep(instruction="左转", road="测试路",
                                      distance_m=per, action="左转",
                                      polyline=pts[lo:hi + 1]))
        else:
            steps = [PlanStep(instruction="直行", road="测试路",
                              distance_m=distance, action="", polyline=pts)]
        return PlanResult(distance_m=distance, duration_s=distance / 1.25,
                          points=pts, steps=steps)


class TestCalibrate(unittest.TestCase):
    center = (121.5, 31.2)
    base_only = [SkeletonVariant(8, 1.0, 0.0, 0.15, 8, "base")]

    def test_converges(self):
        cr = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                       tol_m=500, max_iters=8, detour_factor=1.4)
        self.assertIsNotNone(cr.loop)
        self.assertTrue(cr.loop.ok)
        self.assertLessEqual(abs(cr.best_error_m), 500)
        self.assertGreater(cr.api_calls, 0)
        # 阶段 J：返回最优闭环的评分与指标
        self.assertIsNotNone(cr.best_score)
        self.assertIsNotNone(cr.best_metrics)

    def test_deterministic(self):
        a = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                      tol_m=500, max_iters=8, detour_factor=1.4)
        b = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                      tol_m=500, max_iters=8, detour_factor=1.4)
        self.assertEqual(a.loop.distance_m, b.loop.distance_m)
        self.assertEqual(a.api_calls, b.api_calls)

    def test_single_variant_legacy_behavior(self):
        """显式单变体 = 旧行为：全失败时 history 每轮一条。"""
        cr = calibrate(AlwaysFailPlanner(), self.center, 10000, 8, 5,
                       tol_m=500, max_iters=4, detour_factor=1.4,
                       variants=self.base_only)
        self.assertIsNone(cr.loop)
        self.assertEqual(len(cr.history), 2)  # 连续 2 次失败即放弃该变体

    def test_all_fail_default_variants(self):
        """默认 3 变体：每个变体连续失败 2 次即跳过 → 共 6 条记录。"""
        cr = calibrate(AlwaysFailPlanner(), self.center, 10000, 8, 5,
                       tol_m=500, max_iters=4, detour_factor=1.4)
        self.assertIsNone(cr.loop)
        self.assertEqual(len(cr.history), 6)
        labels = [h.get("variant") for h in cr.history]
        self.assertEqual(labels.count("lean_ell"), 2)
        self.assertEqual(labels.count("base"), 2)
        self.assertEqual(labels.count("lean_cir"), 2)

    def test_max_calls_budget(self):
        cr = calibrate(AlwaysFailPlanner(), self.center, 10000, 8, 5,
                       tol_m=500, max_iters=8, detour_factor=1.4, max_calls=3)
        self.assertIsNone(cr.loop)
        self.assertEqual(cr.api_calls, 3)
        self.assertEqual(len(cr.history), 3)

    def test_early_stop_on_high_quality(self):
        """Mock 直线网络里首个变体（lean_ell）达标即高质量（0 转弯）→ 提前终止。"""
        cr = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                       tol_m=500, max_iters=8, detour_factor=1.4)
        labels = {h.get("variant") for h in cr.history if h.get("variant")}
        self.assertEqual(labels, {"lean_ell"})

    def test_prefers_higher_quality_variant(self):
        """首个变体达标但转弯极多（低分）→ 继续尝试后续变体，最终选评分更高者。"""
        first_variant = plan_variants(10000, 8, 5)[0]
        # 先用纯 Mock 跑单变体，确定首个变体阶段消耗多少次调用
        probe = calibrate(MockPlanner(factor=1.4), self.center, 10000, 8, 5,
                          tol_m=500, max_iters=8, detour_factor=1.4,
                          variants=[first_variant])
        self.assertIsNotNone(probe.loop)
        cr = calibrate(QualityRiggedPlanner(factor=1.4, rig_calls=probe.api_calls),
                       self.center, 10000, 8, 5,
                       tol_m=500, max_iters=8, detour_factor=1.4)
        self.assertIsNotNone(cr.loop)
        labels = {h.get("variant") for h in cr.history if h.get("variant")}
        self.assertIn(first_variant.label, labels)
        self.assertGreater(len(labels), 1)  # 低分未提前终止，尝试了后续变体
        # 最优闭环应来自低转弯的后续变体（首个变体被塞了 45+ 次左转；
        # 后续变体在 Mock 直线网里只剩 waypoint 处的几何转弯 ≈ 点数）
        self.assertLess(cr.best_metrics.get("turns"), 10)
        first_scores = [h["score"] for h in cr.history
                        if h.get("variant") == first_variant.label and "score" in h]
        self.assertGreater(cr.best_score, max(first_scores))


class TestSelectionLogic(unittest.TestCase):
    def test_is_better_first_wins(self):
        self.assertTrue(_is_better(100.0, 50.0, None, None, 500))

    def test_is_better_within_beats_outside(self):
        self.assertTrue(_is_better(400.0, 30.0, 600.0, 90.0, 500))
        self.assertFalse(_is_better(-600.0, 90.0, 400.0, 30.0, 500))

    def test_is_better_score_among_within(self):
        self.assertTrue(_is_better(300.0, 80.0, 400.0, 60.0, 500))
        self.assertFalse(_is_better(300.0, 50.0, 400.0, 60.0, 500))

    def test_is_better_error_among_outside(self):
        self.assertTrue(_is_better(600.0, 10.0, 900.0, 5.0, 500))
        self.assertFalse(_is_better(900.0, 10.0, 600.0, 5.0, 500))

    def test_should_stop_early(self):
        good_m = {"turn_density": 1.2, "uturns": 0, "sharp_turns": 1}
        self.assertFalse(_should_stop_early(600.0, 90.0, good_m, 500))
        self.assertTrue(_should_stop_early(300.0, 60.0, good_m, 500))
        self.assertTrue(_should_stop_early(-300.0, 40.0, good_m, 500))
        bad_m = {"turn_density": 1.2, "uturns": 1, "sharp_turns": 0}
        self.assertFalse(_should_stop_early(300.0, 40.0, bad_m, 500))
        dense = {"turn_density": 3.0, "uturns": 0, "sharp_turns": 0}
        self.assertFalse(_should_stop_early(300.0, 40.0, dense, 500))


if __name__ == "__main__":
    unittest.main()
