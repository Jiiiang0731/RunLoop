#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""环线生成相关的数据结构定义。"""
from dataclasses import dataclass, field
from typing import List, Optional

from .geo import GeoPoint


@dataclass
class PlanStep:
    """一步导航指令（来自高德步行规划 steps）。"""
    instruction: str = ""
    road: str = ""
    distance_m: float = 0.0
    duration_s: float = 0.0
    action: str = ""
    orientation: str = ""
    polyline: List[GeoPoint] = field(default_factory=list)


@dataclass
class PlanResult:
    """一次路径规划结果。error 为 None 表示成功。"""
    distance_m: float = 0.0
    duration_s: float = 0.0
    points: List[GeoPoint] = field(default_factory=list)
    steps: List[PlanStep] = field(default_factory=list)
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        return self.error is None


@dataclass
class RouteSegment:
    index: int
    origin: GeoPoint
    destination: GeoPoint
    distance_m: float
    duration_s: float
    n_points: int
    steps: List[PlanStep] = field(default_factory=list)


@dataclass
class LoopRoute:
    """一条闭合环线。error 为 None 表示成功闭合。"""
    distance_m: float
    duration_s: float
    closure_m: float          # 起终点直线距离
    start_snap_m: float       # 起点到最近可通行道路的吸附距离
    polyline: List[GeoPoint]
    segments: List[RouteSegment]
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        return self.error is None


@dataclass
class ScoreComponent:
    name: str
    score: Optional[float]    # 0~100，None 表示该维度无可靠数据
    weight: float
    available: bool
    detail: str


@dataclass
class ScoreResult:
    total: float
    components: List[ScoreComponent]
    unavailable: List[str]


@dataclass
class CalibrateResult:
    loop: Optional[LoopRoute]
    best_error_m: Optional[float]
    api_calls: int
    history: List[dict]
    best_score: Optional[float] = None      # 最优闭环的质量评分（阶段 J）
    best_metrics: Optional[dict] = None     # 最优闭环的转弯/直行/重复指标（阶段 J）


@dataclass
class GenerateOptions:
    target_m: int
    n_points: int = 0          # 0 = 按目标距离自适应
    seeds: List[int] = field(default_factory=lambda: [1, 2, 3])
    tol_m: int = 500           # 硬约束（阶段 K 决策#1：绝对 ±500m，不改相对容差）
    max_iters: int = 8
    detour_factor: float = 1.7
    sleep_s: float = 0.02
    jitter: float = 0.15
    max_candidates: int = 3       # 生成到这么多个成功候选即停
    max_api_calls: int = 800      # 硬预算，超过即停止（阶段 K 决策#2：质量优先，预算上调）
    per_seed_calls: int = 240     # 单种子调用上限（阶段 K：质量优先 + 绕行修复余量）
    fix_detours: bool = True      # 阶段 K：达标路线做无效绕行替换（spur_fix）


@dataclass
class Candidate:
    seed: int
    loop: Optional[LoopRoute]
    score: Optional[ScoreResult]
    api_calls: int
    elapsed_s: float
    history: List[dict]
    error: Optional[str] = None
    metrics: Optional[dict] = None
    recommended: bool = False    # 评分最高的达标候选（阶段 J：排序后置顶）


@dataclass
class GenerateResult:
    target_m: int
    start: GeoPoint
    candidates: List[Candidate]
    total_api_calls: int
    total_elapsed_s: float
    stage_times: dict = field(default_factory=dict)
