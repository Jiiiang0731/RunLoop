#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""calibrate × spur_fix 集成测试（离线 Mock）：验证用户规范 3.3 的完整链路——
修复后复检 ±tol → 超差则按修复后距离重校 R 重建 → 仍超差回退（硬约束优先）。
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.route_generator.geo import haversine
from backend.route_generator.planner import MockPlanner
from backend.route_generator.spur_fix import find_spur_intervals
from backend.route_generator.types import PlanResult, PlanStep
from backend.route_generator.variants import SkeletonVariant
from backend.route_generator.calibrator import calibrate

START = (114.087279, 30.536395)
MLAT = 110574.0


def _arc(pts):
    return sum(haversine(pts[i - 1], pts[i]) for i in range(1, len(pts)))


def _interp(a, b, n):
    return [(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n)
            for k in range(n + 1)]


class SpurMockPlanner(MockPlanner):
    """OD 直线距离落在 band 内时，在中点注入「支路折返」（北行 220m 原路返回）。

    模拟高德在支路/控制点附近产生的无效绕行；短 OD（绕行进出口之间的替换
    调用）走父类直线，保证 fix_spurs 的替换路径明显更短。
    """

    def __init__(self, band=(430.0, 560.0), spur_h=220.0):
        super().__init__(factor=1.4, n_samples=8)
        self.band = band
        self.spur_h = spur_h

    def plan_walking(self, origin, dest):
        s = haversine(origin, dest)
        if not (self.band[0] <= s < self.band[1]):
            return super().plan_walking(origin, dest)
        self.calls += 1
        mid = ((origin[0] + dest[0]) / 2.0, (origin[1] + dest[1]) / 2.0)
        top = (mid[0], mid[1] + self.spur_h / MLAT)
        s0 = _interp(origin, mid, 8)
        s1 = _interp(mid, top, 4)
        s2 = _interp(top, mid, 4)
        s3 = _interp(mid, dest, 8)
        pts = s0 + s1 + s2 + s3
        steps = [
            PlanStep(instruction="沿主路直行", road="主路", distance_m=_arc(s0), polyline=s0),
            PlanStep(instruction="左转进入支路", road="支路", distance_m=_arc(s1),
                     action="左转", polyline=s1),
            PlanStep(instruction="右转返回主路", road="支路", distance_m=_arc(s2),
                     action="右转", polyline=s2),
            PlanStep(instruction="沿主路直行", road="主路", distance_m=_arc(s3), polyline=s3),
        ]
        return PlanResult(distance_m=_arc(pts), duration_s=_arc(pts) / 1.25,
                          points=pts, steps=steps)


def _variant():
    return SkeletonVariant(n_points=3, aspect=1.0, angle_deg=0.0,
                           jitter=0.0, max_iters=5, label="test")


class TestCalibrateSpurIntegration(unittest.TestCase):
    def test_fix_triggers_recalibration_and_lands_in_tolerance(self):
        """带绕行收敛(≈3029m) → 修复(−880m)出容差 → 重校 R 重建 → 达标且无绕行。"""
        planner = SpurMockPlanner()
        cr = calibrate(planner, START, 3000, 3, seed=1, tol_m=500,
                       variants=[_variant()], fix_detours=True)
        self.assertIsNotNone(cr.loop)
        err = cr.loop.distance_m - 3000
        self.assertLessEqual(abs(err), 500, f"硬约束 ±500m 被破坏：err={err}")
        # 修复后不允许残留绕行
        self.assertEqual(find_spur_intervals(cr.loop.polyline), [])
        events = [h.get("event") for h in cr.history if "event" in h]
        self.assertIn("spur_fix", events)
        self.assertIn("spur_recal", events)
        self.assertIn("spur_recal_accept", events)
        # 重校后版本必须优于带绕行版本（评分对比；绕行自身 100% 重复被消除）
        first_score = next(h["score"] for h in cr.history if "score" in h and "event" not in h)
        self.assertGreater(cr.best_score, first_score)
        self.assertLess(cr.best_metrics["repetition_ratio"], 0.20)

    def test_fix_detours_disabled_keeps_spurs(self):
        """fix_detours=False：保留原行为（不调用修复、路线带绕行但达标）。"""
        planner = SpurMockPlanner()
        cr = calibrate(planner, START, 3000, 3, seed=1, tol_m=500,
                       variants=[_variant()], fix_detours=False)
        self.assertIsNotNone(cr.loop)
        self.assertLessEqual(abs(cr.loop.distance_m - 3000), 500)
        # 只断言“修复类”事件为空；refine_early_stop 是阶段 Q 的搜索诊断。
        events = [h.get("event") for h in cr.history
                  if h.get("event") and (
                      h["event"].startswith("spur") or
                      h["event"].startswith("partial") or
                      h["event"].startswith("recal"))]
        self.assertEqual(events, [])
        # 两处真实折返绕行仍在（V 形单点巧合已被并拢度过滤，不会误报）
        self.assertEqual(len(find_spur_intervals(cr.loop.polyline)), 2)

    def test_deterministic_same_seed_same_result(self):
        """同 seed 同参数两次运行结果一致（可复现性回归）。"""
        cr1 = calibrate(SpurMockPlanner(), START, 3000, 3, seed=1, tol_m=500,
                        variants=[_variant()], fix_detours=True)
        cr2 = calibrate(SpurMockPlanner(), START, 3000, 3, seed=1, tol_m=500,
                        variants=[_variant()], fix_detours=True)
        self.assertAlmostEqual(cr1.loop.distance_m, cr2.loop.distance_m, delta=0.01)
        self.assertEqual(cr1.api_calls, cr2.api_calls)


if __name__ == "__main__":
    unittest.main()
