#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：walk_type 语义与「安全/连续性/车流」分离口径的单元测试。"""
import unittest

from backend.route_generator.quality import (
    WALK_TYPE_LABELS, build_quality, road_continuity, walk_type_profile,
)
from backend.route_generator.types import LoopRoute, PlanStep


def _loop(closure_m=3.0):
    return LoopRoute(distance_m=1000.0, duration_s=500.0,
                     closure_m=closure_m, start_snap_m=2.0,
                     polyline=[(114.0, 30.5), (114.001, 30.5)],
                     segments=[])


def _metrics():
    return {
        "turn_density": 1.0, "turns": 2, "straight_max_m": 300.0,
        "straight_ratio_300": 0.6, "straight_avg_m": 400.0,
        "repetition_ratio": 0.05,
        "walk_type_profile": walk_type_profile([], 1000.0),
    }


class TestWalkTypeSemantics(unittest.TestCase):
    def test_documented_labels_and_unknown_value(self):
        steps = [
            PlanStep(distance_m=100.0, walk_type="0"),
            PlanStep(distance_m=50.0, walk_type="3"),
            PlanStep(distance_m=30.0, walk_type="20"),  # 实测未收录值
        ]
        p = walk_type_profile(steps, 180.0)
        self.assertEqual(p["labels"]["0"], "普通道路")
        self.assertEqual(p["labels"]["3"], "地下通道")
        self.assertEqual(p["labels"]["20"], "unclassified")
        self.assertEqual(p["unclassified_counts"], {"20": 1})
        self.assertEqual(p["unclassified_distance_m"], {"20": 30.0})
        self.assertAlmostEqual(p["grade_separated_ratio"], 50.0 / 180.0, places=3)
        self.assertNotIn("2", WALK_TYPE_LABELS, "2 不是官方地下通道取值")

    def test_unknown_type_is_not_penalized(self):
        only_unknown = [PlanStep(distance_m=100.0, walk_type="20")]
        p = walk_type_profile(only_unknown, 100.0)
        self.assertEqual(p["grade_separated_ratio"], 0.0)
        self.assertEqual(p["unclassified_counts"], {"20": 1})


class TestQualitySeparation(unittest.TestCase):
    def test_continuity_scored_but_safety_and_traffic_unavailable(self):
        q = build_quality(_loop(), _metrics())
        self.assertTrue(q["road_continuity"]["available"])
        self.assertIsNotNone(q["road_continuity"]["score"])
        self.assertFalse(q["road_safety"]["available"])
        self.assertIsNone(q["road_safety"]["score"])
        self.assertFalse(q["traffic_exposure"]["available"])
        self.assertIsNone(q["traffic_exposure"]["score"])
        self.assertIn("lighting", q["data_gaps"])
        self.assertIn("road_width", q["data_gaps"])
        self.assertIn("realtime_traffic", q["data_gaps"])
        # 未请求驾车核验时明确不可用，不能编一个 0/1 分
        self.assertFalse(q["motor_vehicle_access"]["available"])
        self.assertIsNone(q["motor_vehicle_access"]["score"])

    def test_drivable_ratio_is_auxiliary_not_safety(self):
        drivable = {
            "available": True, "walking_m": 1000.0, "driving_m": 1100.0,
            "driving_to_walking_ratio": 1.1, "segments_ok": 2,
            "segments_total": 2, "partial": False,
            "segments": [{"index": 0, "ok": True}],
        }
        q = build_quality(_loop(), _metrics(), drivable)
        access = q["motor_vehicle_access"]
        self.assertTrue(access["available"])
        self.assertAlmostEqual(access["driving_to_walking_ratio"], 1.1)
        self.assertIsNone(access["score"])
        self.assertIn("safety", access["not_for"])
        self.assertIn("traffic_exposure", access["not_for"])
        # 有驾车数据也不能把安全分变出来
        self.assertFalse(q["road_safety"]["available"])
        self.assertIsNone(q["road_safety"]["score"])

    def test_continuity_unavailable_without_steps(self):
        q = build_quality(_loop(), {})
        self.assertFalse(q["road_continuity"]["available"])
        self.assertIsNone(q["road_continuity"]["score"])
        self.assertFalse(road_continuity(_loop(), {})["available"])


if __name__ == "__main__":
    unittest.main()
