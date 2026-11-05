#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P0 统一转弯模型与保形折线单测（合成数据，不联网）。

每个案例同时验证：
1. TurnEvent 的 kind / 角度 / 里程；
2. 同一条事件被序列化给客户端后字段一致；
3. 反向行走时左右转按实际行进方向翻转。
"""
import math
import unittest

from backend.route_generator.geo import haversine, polyline_length, simplify_rdp
from backend.route_generator.nav_text import build_nav_instructions
from backend.route_generator.turn_events import (
    build_turn_events, events_to_steps, geom_kind, signed_delta,
)
from backend.route_generator.types import PlanStep, RouteSegment


def _line(p0, p1, n=6):
    pts = []
    for i in range(n):
        t = i / (n - 1)
        pts.append((p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t))
    return pts


def _seg(steps, idx=0):
    dist = sum(s.distance_m for s in steps)
    return RouteSegment(index=idx, origin=steps[0].polyline[0],
                        destination=steps[-1].polyline[-1],
                        distance_m=dist, duration_s=dist, n_points=0,
                        steps=steps)


def _events(steps):
    poly = []
    for st in steps:
        poly.extend(st.polyline if not poly else st.polyline[1:])
    ev = build_turn_events([_seg(steps)], poly)
    return ev, poly


def _turn_events(ev):
    return [e for e in ev if e["kind"] in ("left", "right", "uturn")]


class TestTurnEventDirections(unittest.TestCase):
    def test_90_left(self):
        a = _line((0.0, 0.0), (0.001, 0.0))          # 向东
        b = _line((0.001, 0.0), (0.001, 0.001))      # 向北
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a),
                         PlanStep(road="B", distance_m=100, polyline=b)])
        turns = _turn_events(ev)
        self.assertEqual(len(turns), 1)
        self.assertEqual(turns[0]["kind"], "left")
        self.assertLess(turns[0]["signed_deg"], 0)
        # at_m 一律是真实折线累计里程（0.001° 经度 ≈ 111.2m），
        # 不是高德步骤上报的近似 distance_m。
        self.assertAlmostEqual(turns[0]["at_m"], polyline_length(a), delta=2)

    def test_90_right(self):
        a = _line((0.0, 0.0), (0.0, 0.001))          # 向北
        b = _line((0.0, 0.001), (0.001, 0.001))      # 向东
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a),
                         PlanStep(road="B", distance_m=100, polyline=b)])
        turns = _turn_events(ev)
        self.assertEqual(len(turns), 1)
        self.assertEqual(turns[0]["kind"], "right")
        self.assertGreater(turns[0]["signed_deg"], 0)

    def test_45_left_and_right(self):
        # 东 → 东北（左 45°）
        a = _line((0.0, 0.0), (0.001, 0.0))
        b = _line((0.001, 0.0), (0.0017, 0.0007))
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a),
                         PlanStep(road="B", distance_m=100, polyline=b)])
        self.assertEqual(_turn_events(ev)[0]["kind"], "left")
        # 东 → 东南（右 45°）
        c = _line((0.0, 0.0), (0.001, 0.0))
        d = _line((0.001, 0.0), (0.0017, -0.0007))
        ev2, _ = _events([PlanStep(road="A", distance_m=100, polyline=c),
                          PlanStep(road="B", distance_m=100, polyline=d)])
        self.assertEqual(_turn_events(ev2)[0]["kind"], "right")

    def test_straight_has_no_turn_event(self):
        a = _line((0.0, 0.0), (0.001, 0.0))
        b = _line((0.001, 0.0), (0.002, 0.0))
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a),
                         PlanStep(road="A", distance_m=100, polyline=b)])
        self.assertEqual(_turn_events(ev), [])

    def test_uturn(self):
        a = _line((0.0, 0.0), (0.001, 0.0))          # 东
        b = _line((0.001, 0.0), (0.0002, 0.0))       # 回西
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a),
                         PlanStep(road="B", distance_m=90, polyline=b)])
        turns = _turn_events(ev)
        self.assertEqual(turns[0]["kind"], "uturn")
        self.assertGreater(abs(turns[0]["signed_deg"]), 150)

    def test_consecutive_turns_not_swallowed(self):
        """旧实现会把 30m 短步并入上一步，吞掉两个真实转弯。"""
        a = _line((0.0, 0.0), (0.001, 0.0))          # 东
        b = _line((0.001, 0.0), (0.001, 0.0003))     # 北 30m
        c = _line((0.001, 0.0003), (0.002, 0.0003))  # 东
        steps = [
            PlanStep(road="A", distance_m=100, polyline=a, action="右转"),
            PlanStep(road="B", distance_m=30, polyline=b, action="左转"),
            PlanStep(road="C", distance_m=100, polyline=c),
        ]
        kinds = [e["kind"] for e in _turn_events(_events(steps)[0])]
        self.assertEqual(kinds, ["right", "left"])

        nav = build_nav_instructions(steps)
        self.assertEqual([n["turn"] for n in nav][:2], ["right", "left"])

    def test_action_overrides_blind_geometry(self):
        """短步骤几何看不出角度，但高德明确说左转 → 仍必须播左转。"""
        a = _line((0.0, 0.0), (0.001, 0.0))
        # 几何仅约 27°（低于 45° 不算转弯），高德 action 明确说左转。
        b = _line((0.001, 0.0), (0.0012, 0.0001))
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a, action="左转"),
                         PlanStep(road="B", distance_m=25, polyline=b)])
        turn = _turn_events(ev)[0]
        self.assertEqual(turn["kind"], "left")
        self.assertEqual(turn["confidence"], "medium")

    def test_conflicting_action_marks_low_confidence(self):
        a = _line((0.0, 0.0), (0.001, 0.0))          # 东
        b = _line((0.001, 0.0), (0.001, 0.001))      # 北（几何=左）
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a, action="右转"),
                         PlanStep(road="B", distance_m=100, polyline=b)])
        turn = _turn_events(ev)[0]
        self.assertEqual(turn["kind"], "right")      # 结构化 action 优先
        self.assertEqual(turn["confidence"], "low")  # 但明确标记不可靠

    def test_reverse_route_flips_left_to_right(self):
        a = _line((0.0, 0.0), (0.001, 0.0))
        b = _line((0.001, 0.0), (0.001, 0.001))
        ev, _ = _events([PlanStep(road="A", distance_m=100, polyline=a),
                         PlanStep(road="B", distance_m=100, polyline=b)])
        self.assertEqual(_turn_events(ev)[0]["kind"], "left")

        # 反向走：北 → 东，原来的左转应变成右转
        ra = list(reversed(b))
        rb = list(reversed(a))
        ev2, _ = _events([PlanStep(road="B", distance_m=100, polyline=ra),
                          PlanStep(road="A", distance_m=100, polyline=rb)])
        self.assertEqual(_turn_events(ev2)[0]["kind"], "right")

    def test_event_contract_serialization(self):
        a = _line((0.0, 0.0), (0.001, 0.0))
        b = _line((0.001, 0.0), (0.001, 0.001))
        ev, poly = _events([PlanStep(road="A", distance_m=100, polyline=a),
                            PlanStep(road="B", distance_m=100, polyline=b)])
        out = events_to_steps(ev, poly)
        t = _turn_events(out)[0]
        self.assertEqual(t["kind"], "left")
        for k in ("id", "at_m", "angle_deg", "signed_deg", "road_from", "road_to",
                  "junction", "step_index", "confidence", "source"):
            self.assertIn(k, t)


class TestGeomKind(unittest.TestCase):
    def test_thresholds(self):
        self.assertEqual(geom_kind(0), "straight")
        self.assertEqual(geom_kind(30), "straight")    # 轻微弯曲不报
        self.assertEqual(geom_kind(-50), "left")
        self.assertEqual(geom_kind(50), "right")
        self.assertEqual(geom_kind(170), "uturn")

    def test_signed_delta_wrap(self):
        self.assertAlmostEqual(signed_delta(350, 10), 20)
        self.assertAlmostEqual(signed_delta(10, 350), -20)


class TestGeometryPreservingSimplify(unittest.TestCase):
    def test_keeps_corners_and_length(self):
        # 折线：大量共线点 + 一个 90° 拐角；隔点抽稀会裁角
        pts = []
        for i in range(30):
            pts.append((i * 0.00001, 0.0))
        for i in range(1, 30):
            pts.append((0.00029, i * 0.00001))
        out = simplify_rdp(pts, 1.5)
        self.assertLess(len(out), len(pts))
        self.assertEqual(out[0], pts[0])
        self.assertEqual(out[-1], pts[-1])
        # 拐角（最后一段的起点）必须保留
        self.assertTrue(any(abs(p[0] - 0.00029) < 1e-9 and abs(p[1]) < 1e-9 for p in out))
        err = abs(polyline_length(out) - polyline_length(pts)) / polyline_length(pts)
        self.assertLess(err, 0.005, f"简化后长度误差 {err:.3%} 超过 0.5%")

    def test_dense_zigzag_length_preserved(self):
        # 密集锯齿：隔点抽稀会丢掉约一半折返里程，RDP 必须保形
        pts = []
        for i in range(80):
            pts.append((i * 0.00002, 0.00004 if i % 2 else 0.0))
        out = simplify_rdp(pts, 1.0)
        err = abs(polyline_length(out) - polyline_length(pts)) / polyline_length(pts)
        self.assertLess(err, 0.02)


if __name__ == "__main__":
    unittest.main()
