#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""控制点生成：在中心周围生成环形/椭圆形骨架点（由 seed 决定，可复现）。"""
import math
import random
from typing import List

from .geo import GeoPoint


def generate_ring(center: GeoPoint, radius_m: float, n: int, seed: int,
                  jitter: float = 0.15, aspect: float = 1.0,
                  angle_deg: float = 0.0) -> List[GeoPoint]:
    """
    生成 n 个控制点，近似分布在半径 radius_m 的环上。

    - aspect: 椭圆轴比（1.0 = 圆；>1 南北拉长，<1 东西拉长）。
    - angle_deg: 整体旋转角度。
    - jitter: 半径随机抖动比例。
    - 相同 seed + 参数 => 完全相同的点（可复现）。
    """
    rng = random.Random(seed)
    lng, lat = center
    mlat = 110574.0
    mlng = 111320.0 * math.cos(math.radians(lat))
    base = rng.uniform(0, 2 * math.pi)
    rot = math.radians(angle_deg)
    pts: List[GeoPoint] = []
    for i in range(n):
        th = base + 2 * math.pi * i / n
        rr = radius_m * (1 + rng.uniform(-jitter, jitter))
        x = rr * math.cos(th)            # 东西向
        y = rr * math.sin(th) * aspect   # 南北向（受 aspect 缩放）
        xr = x * math.cos(rot) - y * math.sin(rot)
        yr = x * math.sin(rot) + y * math.cos(rot)
        pts.append((round(lng + xr / mlng, 6), round(lat + yr / mlat, 6)))
    return pts
