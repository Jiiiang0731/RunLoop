#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""spur_fix（无效绕行识别与替换）单元测试：全部离线 Mock，不消耗 API。"""
import math
import sys
import os
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.route_generator.geo import haversine
from backend.route_generator.planner import MockPlanner
from backend.route_generator.spur_fix import (
    _build_index_map, _count_geo_turns, _fold_ratio,
    find_spur_intervals, fix_spurs,
)
from backend.route_generator.types import LoopRoute, PlanStep, RouteSegment

LAT0, LNG0 = 30.0, 114.0
MLAT = 110574.0
MLNG = 111320.0 * math.cos(math.radians(LAT0))
STEP_E = 48.0   # 东西向点距（米）
STEP_N = 55.0   # 南北向点距（米）


def _east(k):
    return (LNG0 + STEP_E * k / MLNG, LAT0)


def _north(h, lng):
    return (lng, LAT0 + h / MLAT)


def _spur_polyline():
    """带支路折返的折线：东行20点 → 北行5点 → 原路返回5点 → 继续东行20点。

    折返段（spur）弧长 ~495m、空间上完全重叠 → 应被识别为无效绕行。
    """
    pts = [_east(k) for k in range(20)]           # 0..19，J=pts[19]
    jlng = pts[19][0]
    pts += [_north(STEP_N * k, jlng) for k in range(1, 6)]   # 20..24 北行
    pts += [_north(STEP_N * k, jlng) for k in range(4, -1, -1)]  # 25..29 南行回到 J
    pts += [(jlng + STEP_E * k / MLNG, LAT0) for k in range(1, 21)]  # 30..49 东行
    return pts


def _arc_len(pts):
    return sum(haversine(pts[i - 1], pts[i]) for i in range(1, len(pts)))


def _make_loop(polyline, step_sizes=(20, 5, 5, 20)):
    """按 step_sizes 把折线切成一个 segment 的多个 steps（模拟 AMap step 粒度）。"""
    steps = []
    idx = 0
    for size in step_sizes:
        chunk = polyline[idx:idx + size]
        steps.append(PlanStep(instruction="直行", road="测试路",
                              distance_m=_arc_len(chunk) if len(chunk) > 1 else 0.0,
                              polyline=chunk))
        idx += size
    assert idx == len(polyline)
    seg = RouteSegment(index=0, origin=polyline[0], destination=polyline[-1],
                       distance_m=_arc_len(polyline), duration_s=100.0,
                       n_points=len(polyline), steps=steps)
    return LoopRoute(distance_m=_arc_len(polyline), duration_s=100.0,
                     closure_m=0.0, start_snap_m=0.0,
                     polyline=list(polyline), segments=[seg])


class TestFindSpurIntervals(unittest.TestCase):
    def test_detects_spur(self):
        pts = _spur_polyline()
        ivs = find_spur_intervals(pts)
        self.assertEqual(len(ivs), 1, f"应恰好识别 1 个绕行区间，实得 {ivs}")
        i, j = ivs[0]
        # 区间必须覆盖折返段（南北两腿），入口不晚于北腿起点、出口不早于回到 J
        self.assertLessEqual(i, 20)
        self.assertGreaterEqual(j, 29)

    def test_no_spur_on_straight_line(self):
        pts = [_east(k) for k in range(40)]
        self.assertEqual(find_spur_intervals(pts), [])

    def test_closure_not_flagged(self):
        """闭合环线首尾空间重合但弧长≈全程，必须被 max_span 保护排除。"""
        n = 60
        pts = []
        for k in range(n + 1):
            th = 2 * math.pi * k / n
            pts.append((LNG0 + 900 * math.cos(th) / MLNG,
                        LAT0 + 900 * math.sin(th) / MLAT))
        self.assertEqual(find_spur_intervals(pts), [])

    def test_short_polyline_safe(self):
        self.assertEqual(find_spur_intervals([_east(0), _east(1)]), [])


class TestFixSpurs(unittest.TestCase):
    def test_replaces_spur_with_shorter_path(self):
        pts = _spur_polyline()
        loop = _make_loop(pts)
        planner = MockPlanner(factor=1.4)
        res = fix_spurs(loop, planner)
        self.assertEqual(len(res.fixes), 1)
        self.assertEqual(res.calls, 1)
        fix = res.fixes[0]
        # 原折返 ~495m，替换为 ~77m（Mock 直线×1.4）
        self.assertGreater(fix.saved_m, 300)
        self.assertLess(fix.repl_m, 150)
        # 距离变短且与新折线一致
        self.assertLess(res.loop.distance_m, loop.distance_m - 300)
        self.assertAlmostEqual(res.loop.distance_m,
                               loop.distance_m - fix.span_m + fix.repl_m, delta=60)
        # 原对象不被修改
        self.assertEqual(len(loop.polyline), 50)

    def test_spliced_polyline_continuous(self):
        """拼接后不得出现空间跳变（禁止直线飞越的连续性验证）。"""
        loop = _make_loop(_spur_polyline())
        res = fix_spurs(loop, MockPlanner(factor=1.4))
        new_pts = res.loop.polyline
        max_gap = max(haversine(new_pts[i - 1], new_pts[i]) for i in range(1, len(new_pts)))
        self.assertLess(max_gap, 100.0, f"拼接后最大点距 {max_gap:.0f}m 超限")

    def test_steps_stay_consistent_with_polyline(self):
        """修复后 steps 拼接必须仍与折线一一对应（导航文本可重建）。"""
        loop = _make_loop(_spur_polyline())
        res = fix_spurs(loop, MockPlanner(factor=1.4))
        mapping = _build_index_map(res.loop)
        self.assertIsNotNone(mapping, "修复后 index_map 失效：steps 与折线不一致")
        concat = []
        for seg in res.loop.segments:
            for st in seg.steps:
                concat.extend(st.polyline)
        self.assertEqual(len(concat), len(res.loop.polyline))
        for a, b in zip(concat, res.loop.polyline):
            self.assertAlmostEqual(a[0], b[0], places=9)
            self.assertAlmostEqual(a[1], b[1], places=9)

    def test_rejects_when_replacement_not_shorter(self):
        """替换路径不够短（factor 大）→ 拒绝，保持原路线。"""
        loop = _make_loop(_spur_polyline())
        res = fix_spurs(loop, MockPlanner(factor=10.0))
        self.assertEqual(res.fixes, [])
        self.assertEqual(res.calls, 1)  # 尝试过 1 次
        self.assertIs(res.loop, loop)
        self.assertTrue(any(a.get("reject") == "saving" for a in res.attempts))

    def test_no_spur_zero_calls(self):
        loop = _make_loop([_east(k) for k in range(40)], step_sizes=(40,))
        res = fix_spurs(loop, MockPlanner())
        self.assertEqual(res.fixes, [])
        self.assertEqual(res.calls, 0)
        self.assertIs(res.loop, loop)

    def test_broken_mapping_aborts_safely(self):
        """segments/steps 与折线对不上时安全放弃（返回原路线、0 调用）。"""
        pts = _spur_polyline()
        loop = _make_loop(pts)
        loop.segments[0].steps = loop.segments[0].steps[:2]  # 故意破坏一致性
        res = fix_spurs(loop, MockPlanner())
        self.assertIs(res.loop, loop)
        self.assertEqual(res.calls, 0)

    def test_turn_count_helper(self):
        # 直线 0 转弯；直角 1 转弯；掉头 1 转弯（≥45° 阈值）
        straight = [_east(k) for k in range(5)]
        self.assertEqual(_count_geo_turns(straight), 0)
        corner = [_east(0), _east(1), _north(55, _east(1)[0]), _north(110, _east(1)[0])]
        self.assertEqual(_count_geo_turns(corner), 1)


class TestFoldRatio(unittest.TestCase):
    """双向并拢度结构校验：真折返 ≈1，V 形单点巧合 ≈0（用户规范 2.1/3.1）。"""

    @staticmethod
    def _xy_arc(pts):
        arc = [0.0]
        for k in range(1, len(pts)):
            arc.append(arc[-1] + math.hypot(pts[k][0] - pts[k - 1][0],
                                           pts[k][1] - pts[k - 1][1]))
        return pts, arc

    def test_out_and_back_folds(self):
        # 北向 5 边 + 原路折返 5 边（坐标完全重合）
        pts = [(0.0, 50.0 * k) for k in range(6)] + [(0.0, 50.0 * k) for k in range(4, -1, -1)]
        xy, arc = self._xy_arc(pts)
        r = _fold_ratio(xy, arc, 0, len(pts) - 1, match_m=25.0)
        self.assertGreater(r, 0.7, f"真折返并拢度应接近 1，实得 {r:.2f}")

    def test_v_shape_coincidence_not_folded(self):
        # L 形：东行 450m 再北行 450m，仅在拐点单点接近
        pts = [(50.0 * k, 0.0) for k in range(10)] + [(450.0, 50.0 * k) for k in range(1, 10)]
        xy, arc = self._xy_arc(pts)
        r = _fold_ratio(xy, arc, 0, len(pts) - 1, match_m=25.0)
        self.assertLess(r, 0.3, f"V 形巧合不应判为绕行，实得 {r:.2f}")

    def test_sparse_sampling_still_folds(self):
        # 稀疏采样（60m 边长）的去/返两腿，自适应匹配半径仍应识别
        pts = [(0.0, 60.0 * k) for k in range(6)] + [(0.0, 60.0 * k) for k in range(4, -1, -1)]
        xy, arc = self._xy_arc(pts)
        r = _fold_ratio(xy, arc, 0, len(pts) - 1, match_m=25.0)
        self.assertGreater(r, 0.7, f"稀疏采样折返并拢度应足够高，实得 {r:.2f}")


if __name__ == "__main__":
    unittest.main()
