#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""骨架变体规划（阶段 J）：按目标距离与种子生成确定性的环骨架配置序列。

设计动机（蔡甸区真实 API 探索标定，见 docs/phase_j_report.md）：
- 闭环转弯数 ≈ 控制点数（每个 waypoint 附近通常强制一次转弯）+ 分段内路网转弯；
- 阶段 I 圆形 9 点骨架 15km 转弯密度高达 2.0~2.2 次/km；
- 探索实测：更少的控制点（15km 用 6 点）+ 低抖动 + 适度椭圆轴比（1.5），
  转弯密度可降到 1.1~1.65 次/km，评分从 ~41 提升到 51~69；
- 但少点骨架对某些 seed 会「距离断层」不收敛——故保留圆形多点 base 作收敛兜底。

策略：按「少转弯椭圆(lean_ell) → 圆形多点兜底(base) → 低抖动圆(lean_cir)」顺序尝试，
配合质量评分与提前终止，在控制 API 调用的前提下优先返回少转弯路线。
所有变体由 (target_m, n_points, seed) 完全确定，可复现。
"""
from dataclasses import dataclass
from typing import List


@dataclass(frozen=True)
class SkeletonVariant:
    """一个环骨架配置。"""
    n_points: int       # 控制点数量
    aspect: float       # 椭圆/矩形轴比（1.0=圆/方，>1 南北拉长）
    angle_deg: float    # 整体旋转角（度）
    jitter: float       # 半径随机抖动比例
    max_iters: int      # 该变体的 R 缩放迭代预算（1 = 网格模式，只建一次）
    label: str          # 展示/日志用标签
    shape: str = "ring"  # 骨架曲线：ring / fig8 / petal / rect（阶段 N）
    radius_factor: float = 1.0  # 阶段 N：短距离网格的半径倍率（相对 R_init）
    # 阶段 N：骨架中心相对起点的偏移（自然环线常常不以起点为圆心——
    # 实测校园环线中心比起点偏移约 450m，同心圆骨架因此永远找不到它）。
    offset_dir_deg: float = -1.0   # 偏移方位（正北顺时针；-1 = 不偏移）
    offset_factor: float = 0.0     # 偏移量 = offset_factor × R


def lean_n_points(n_points: int) -> int:
    """少转弯变体的控制点数：约为 base 的 0.62 倍，下限 5。

    实测标定（蔡甸真实 API 探索）：
    - 15km(base 9)→6：评分 41→51~69，密度 2.03→1.14~1.65；
    - 20km(base 10)→6：评分 33→50~56，密度 2.24→1.25~1.57（7 点反而不收敛）；
    - 10km(base 6)→5：转弯 35→23，密度 3.32→2.21；
    - 5km(base 5)→5：减点无意义，plan_variants 只返回 base。
    """
    return max(5, int(round(n_points * 0.62)))


# 阶段 N：短距离（≤3km）专用阈值。低于该距离时街区尺度主导，
# 圆形骨架 + R 定点迭代会振荡（实测 1km 出现 586m/−41%，64 次调用不收敛）。
SHORT_DISTANCE_M = 3000


def plan_variants(target_m: int, n_points: int, seed: int,
                  base_jitter: float = 0.15,
                  base_max_iters: int = 8) -> List[SkeletonVariant]:
    """返回按尝试顺序排列的骨架变体。

    阶段 N 分两条路径：
    - 短距离（≤3km）：**半径×形状确定性网格**，每个变体只建一次（max_iters=1），
      取误差最小且通过质量门限者；不再用 R 定点迭代（距离对半径高度不连续，
      实测在两值间无限振荡）。8 个控制点让骨架能贴合街区/校园拐角。
    - 长距离（>3km）：沿用阶段 J/K 的「少转弯椭圆 → 多点圆兜底 → 低抖动圆」，
      保持 15km/50km 已验证的质量。
    """
    if target_m <= SHORT_DISTANCE_M:
        n = max(n_points, 8)
        a = float((seed * 37) % 90)
        return [
            # 中等矩形：城市街区/校园外围最常见的自然形态（周长与圆等长）
            SkeletonVariant(n, 1.0, a, 0.0, 1, "grid_rect", shape="rect"),
            SkeletonVariant(n, 1.0, a, 0.05, 1, "grid_ring"),
            # 偏移中心：覆盖「起点在环线一角」的自然环线（校园/公园/街区外围）
            SkeletonVariant(n, 1.0, 135.0, 0.05, 1, "grid_off_se",
                            shape="rect", offset_dir_deg=135.0,
                            offset_factor=0.9),
            SkeletonVariant(n, 1.0, 45.0, 0.05, 1, "grid_off_ne",
                            shape="rect", offset_dir_deg=45.0,
                            offset_factor=0.9),
            SkeletonVariant(n, 1.0, 225.0, 0.05, 1, "grid_off_sw",
                            shape="rect", offset_dir_deg=225.0,
                            offset_factor=0.9),
            SkeletonVariant(n, 1.0, 315.0, 0.05, 1, "grid_off_nw",
                            shape="rect", offset_dir_deg=315.0,
                            offset_factor=0.9),
            SkeletonVariant(n, 1.0, a + 30, 0.04, 1, "grid_rect_big",
                            shape="rect", radius_factor=1.25),
            SkeletonVariant(n, 1.0, 135.0, 0.05, 1, "grid_off_se_big",
                            shape="rect", offset_dir_deg=135.0,
                            offset_factor=1.25),
        ]
    lean_n = lean_n_points(n_points)
    base = SkeletonVariant(n_points=n_points, aspect=1.0, angle_deg=0.0,
                           jitter=base_jitter, max_iters=base_max_iters, label="base")
    if lean_n >= n_points:
        return [base]
    a1 = float((seed * 47) % 180)
    a2 = float((seed * 47 + 90) % 180)
    # lean 变体 max_iters=6：探索实测 20km 少点椭圆需 ~6 次 R 缩放才收敛进容差，
    # 5 次会差几十米卡在容差外、白白回退到高转弯的 base（见 docs/phase_j_report.md）。
    return [
        SkeletonVariant(n_points=lean_n, aspect=1.5, angle_deg=a1,
                        jitter=0.10, max_iters=6, label="lean_ell"),
        base,
        SkeletonVariant(n_points=lean_n, aspect=1.3, angle_deg=a2,
                        jitter=0.07, max_iters=6, label="lean_cir"),
    ]
