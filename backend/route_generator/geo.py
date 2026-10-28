#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""地理工具：距离、折线解析/长度、坐标系转换（WGS-84 <-> GCJ-02）。"""
import math
from typing import List, Tuple

# 坐标统一约定：GeoPoint = (lng, lat)，规划/展示一律 GCJ-02；GPS 原始值为 WGS-84。
GeoPoint = Tuple[float, float]

_EARTH_R = 6371000.0
# GCJ-02 偏移常量（公开通用算法，用于离线转换，已与高德在线转换接口交叉验证）
_A = 6378245.0
_EE = 0.00669342162296594323


def haversine(a: GeoPoint, b: GeoPoint) -> float:
    """两点直线距离（米）。"""
    lng1, lat1 = math.radians(a[0]), math.radians(a[1])
    lng2, lat2 = math.radians(b[0]), math.radians(b[1])
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2)
    return 2 * _EARTH_R * math.asin(math.sqrt(h))


def polyline_length(pts: List[GeoPoint]) -> float:
    """折线总长度（米）。"""
    return sum(haversine(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def parse_polyline(s: str) -> List[GeoPoint]:
    """解析高德步行折线：'lng,lat;lng,lat;...' -> [(lng,lat), ...]。"""
    pts: List[GeoPoint] = []
    for chunk in (s or "").split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = chunk.split(",")
        if len(parts) == 2:
            try:
                pts.append((float(parts[0]), float(parts[1])))
            except ValueError:
                pass
    return pts


def _out_of_china(lng: float, lat: float) -> bool:
    return not (72.004 <= lng <= 137.8347 and 0.8293 <= lat <= 55.8271)


def _transform_lat(x: float, y: float) -> float:
    ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320.0 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    return ret


def _transform_lng(x: float, y: float) -> float:
    ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0
    return ret


def wgs84_to_gcj02(lng: float, lat: float) -> GeoPoint:
    """WGS-84(GPS) -> GCJ-02(高德)。"""
    if _out_of_china(lng, lat):
        return lng, lat
    dlat = _transform_lat(lng - 105.0, lat - 35.0)
    dlng = _transform_lng(lng - 105.0, lat - 35.0)
    radlat = lat / 180.0 * math.pi
    magic = math.sin(radlat)
    magic = 1 - _EE * magic * magic
    sqrtmagic = math.sqrt(magic)
    dlat = (dlat * 180.0) / ((_A * (1 - _EE)) / (magic * sqrtmagic) * math.pi)
    dlng = (dlng * 180.0) / (_A / sqrtmagic * math.cos(radlat) * math.pi)
    return lng + dlng, lat + dlat


def gcj02_to_wgs84(lng: float, lat: float) -> GeoPoint:
    """GCJ-02 -> WGS-84（一步近似反解，国内误差约 1~2 米，满足跑步场景）。"""
    if _out_of_china(lng, lat):
        return lng, lat
    glng, glat = wgs84_to_gcj02(lng, lat)
    return lng - (glng - lng), lat - (glat - lat)
