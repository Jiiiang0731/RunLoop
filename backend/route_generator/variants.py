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
    aspect: float       # 椭圆轴比（1.0=圆，>1 南北拉长）
    angle_deg: float    # 整体旋转角（度）
    jitter: float       # 半径随机抖动比例
    max_iters: int      # 该变体的 R 缩放迭代预算
    label: str          # 展示/日志用标签
    shape: str = "ring"  # 骨架曲线：ring / fig8 / petal（阶段 K 决策#4）


def lean_n_points(n_points: int) -> int:
    """少转弯变体的控制点数：约为 base 的 0.62 倍，下限 5。

    实测标定（蔡甸真实 API 探索）：
    - 15km(base 9)→6：评分 41→51~69，密度 2.03→1.14~1.65；
    - 20km(base 10)→6：评分 33→50~56，密度 2.24→1.25~1.57（7 点反而不收敛）；
    - 10km(base 6)→5：转弯 35→23，密度 3.32→2.21；
    - 5km(base 5)→5：减点无意义，plan_variants 只返回 base。
    """
    return max(5, int(round(n_points * 0.62)))


def plan_variants(target_m: int, n_points: int, seed: int,
                  base_jitter: float = 0.15,
                  base_max_iters: int = 8) -> List[SkeletonVariant]:
    """返回按尝试顺序排列的骨架变体。

    - lean_ell：少点椭圆（主减转弯变体，最先尝试；高分则提前终止省调用）；
    - base：圆形多点（收敛可靠，作为距离断层时的兜底）；
    - lean_cir：少点低抖动椭圆（补充多样性，仅在前两者都可能不达标时兜底）。

    当少点变体无法真正减少控制点数（如 5km base 已是 5 点）时，减点无意义、
    只会重复消耗调用，此时仅返回 base 单变体（与旧行为一致、成本最低）。
    角度由 seed 确定性推导，不同 seed 探索不同方向。
    """
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
