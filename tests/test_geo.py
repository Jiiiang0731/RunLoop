#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""geo 模块单元测试。"""
import unittest

from backend.route_generator import (
    gcj02_to_wgs84, haversine, parse_polyline, polyline_length, wgs84_to_gcj02,
)


class TestHaversine(unittest.TestCase):
    def test_one_degree_lat(self):
        d = haversine((116.0, 39.0), (116.0, 40.0))
        self.assertAlmostEqual(d, 111194.9, delta=50)

    def test_small_lng(self):
        d = haversine((0.0, 0.0), (0.001, 0.0))
        self.assertAlmostEqual(d, 111.32, delta=2)


class TestPolyline(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(parse_polyline("116.1,39.2;116.2,39.3"), [(116.1, 39.2), (116.2, 39.3)])

    def test_parse_empty_and_garbage(self):
        self.assertEqual(parse_polyline(""), [])
        self.assertEqual(parse_polyline("abc"), [])

    def test_length_equals_sum(self):
        pts = [(0.0, 0.0), (0.0, 0.001), (0.001, 0.001)]
        expected = haversine(pts[0], pts[1]) + haversine(pts[1], pts[2])
        self.assertAlmostEqual(polyline_length(pts), expected, places=3)


class TestTransform(unittest.TestCase):
    def test_forward_matches_amap(self):
        # 高德在线转换接口实测：WGS-84 (116.391275,39.9075) -> GCJ-02 (116.397515190973,39.908900553386)
        g = wgs84_to_gcj02(116.391275, 39.9075)
        expected = (116.397515190973, 39.908900553386)
        self.assertLess(haversine(g, expected), 15, f"got {g}, expected ~{expected}")

    def test_roundtrip(self):
        p = (116.391275, 39.9075)
        back = gcj02_to_wgs84(*wgs84_to_gcj02(*p))
        self.assertLess(haversine(p, back), 5)

    def test_out_of_china_unchanged(self):
        p = (-73.98, 40.75)  # 纽约，不在中国，应原样返回
        self.assertEqual(wgs84_to_gcj02(*p), p)


if __name__ == "__main__":
    unittest.main()
