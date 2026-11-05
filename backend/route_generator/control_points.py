#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""控制点生成：在中心周围生成环形/椭圆形骨架点（由 seed 决定，可复现）。"""
import math
import random
from typing import List

from .geo import GeoPoint


def generate_ring(center: GeoPoint, radius_m: float, n: int, seed: int,
                  jitter: float = 0.15, aspect: float = 1.0,
                  angle_deg: float = 0.0, shape: str = "ring") -> List[GeoPoint]:
    """
    生成 n 个控制点，按 shape 分布在半径 radius_m 的骨架曲线上。

    - shape: "ring" 圆/椭圆（默认）；"fig8" 双纽线 8 字（Gerono lemniscate）；
      "petal" 四瓣玫瑰线 r = R·cos(2θ)；"rect" 周长等长的矩形（阶段 N：
      城市街区/校园外围更接近矩形而不是圆，短距离专用）。
    - aspect: 椭圆/矩形轴比（1.0 = 方形；>1 南北拉长，<1 东西拉长）。
    - angle_deg: 整体旋转角度。
    - jitter: 半径随机抖动比例（rect 不抖动，保持角点贴合道路转角）。
    - 相同 seed + 参数 => 完全相同的点（可复现）。
    """
    rng = random.Random(seed)
    lng, lat = center
    mlat = 110574.0
    mlng = 111320.0 * math.cos(math.radians(lat))
    base = rng.uniform(0, 2 * math.pi)
    rot = math.radians(angle_deg)
    pts: List[GeoPoint] = []
    if shape == "rect":
        # 周长等长映射：半宽 hw 使矩形周长 4·(1+aspect)·hw ≈ 2πR
        hw = radius_m * math.pi / (2.0 * (1.0 + aspect))
        hh = hw * aspect
        w, h = 2 * hw, 2 * hh
        per = 2 * (w + h)
        for i in range(n):
            d = per * i / n
            if d < w:
                x, y = -hw + d, -hh
            elif d < w + h:
                x, y = hw, -hh + (d - w)
            elif d < 2 * w + h:
                x, y = hw - (d - w - h), hh
            else:
                x, y = -hw, hh - (d - 2 * w - h)
            xr = x * math.cos(rot) - y * math.sin(rot)
            yr = x * math.sin(rot) + y * math.cos(rot)
            pts.append((round(lng + xr / mlng, 6), round(lat + yr / mlat, 6)))
        return pts
    for i in range(n):
        th = base + 2 * math.pi * i / n
        rr = radius_m * (1 + rng.uniform(-jitter, jitter))
        if shape == "fig8":
            # Gerono 双纽线：x = R cos t, y = R sin t cos t（×2 归一化振幅，
            # 使 x/y 半轴与同参数椭圆一致，R 的初值估计仍可复用）
            x = rr * math.cos(th)
            y = rr * math.sin(th) * math.cos(th) * 2.0 * aspect
        elif shape == "petal":
            # 玫瑰线（带符号 r，θ 走一圈遍历全部 4 瓣）
            rm = rr * math.cos(2 * th)
            x = rm * math.cos(th)
            y = rm * math.sin(th) * aspect
        else:
            x = rr * math.cos(th)            # 东西向
            y = rr * math.sin(th) * aspect   # 南北向（受 aspect 缩放）
        xr = x * math.cos(rot) - y * math.sin(rot)
        yr = x * math.sin(rot) + y * math.cos(rot)
        pts.append((round(lng + xr / mlng, 6), round(lat + yr / mlat, 6)))
    return pts
