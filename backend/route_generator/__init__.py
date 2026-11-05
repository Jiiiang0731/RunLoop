#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""环线生成核心库导出。"""
from .geo import (
    GeoPoint, haversine, polyline_length, parse_polyline,
    wgs84_to_gcj02, gcj02_to_wgs84,
)
from .types import (
    PlanResult, RouteSegment, LoopRoute, ScoreComponent, ScoreResult,
    CalibrateResult, GenerateOptions, Candidate, GenerateResult,
)
from .planner import MapPlanner, AmapWalkingPlanner, MockPlanner
from .control_points import generate_ring
from .loop_builder import build_loop
from .calibrator import calibrate
from .scorer import (
    distance_error_score, closure_score, repetition_ratio, repetition_score,
    score_route, DEFAULT_WEIGHTS,
    turn_density_score, long_straight_score, sharp_short_score,
)
from .nav_metrics import analyze_route, detect_turns
from .quality import (
    build_quality, compute_drivable_access, walk_type_profile,
    WALK_TYPE_LABELS, WALK_TYPE_GRADE_SEPARATED,
)
from .anchor_loop import build_anchor_loop
from .variants import SkeletonVariant, plan_variants
from .spur_fix import (
    fix_spurs, find_spur_intervals, SpurFix, SpurFixResult,
)
from .overlap import detect_overlaps
from .generator import generate_candidates, adaptive_n_points, rank_candidates

__all__ = [
    "GeoPoint", "haversine", "polyline_length", "parse_polyline",
    "wgs84_to_gcj02", "gcj02_to_wgs84",
    "PlanResult", "RouteSegment", "LoopRoute", "ScoreComponent", "ScoreResult",
    "CalibrateResult", "GenerateOptions", "Candidate", "GenerateResult",
    "MapPlanner", "AmapWalkingPlanner", "MockPlanner",
    "generate_ring", "build_loop", "calibrate",
    "distance_error_score", "closure_score", "repetition_ratio", "repetition_score",
    "score_route", "DEFAULT_WEIGHTS",
    "turn_density_score", "long_straight_score", "sharp_short_score",
    "analyze_route", "detect_turns", "adaptive_n_points",
    "build_quality", "compute_drivable_access", "walk_type_profile",
    "WALK_TYPE_LABELS", "WALK_TYPE_GRADE_SEPARATED",
    "build_anchor_loop",
    "SkeletonVariant", "plan_variants", "rank_candidates",
    "fix_spurs", "find_spur_intervals", "SpurFix", "SpurFixResult",
    "detect_overlaps",
    "generate_candidates",
]
