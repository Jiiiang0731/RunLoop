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
)
from .generator import generate_candidates

__all__ = [
    "GeoPoint", "haversine", "polyline_length", "parse_polyline",
    "wgs84_to_gcj02", "gcj02_to_wgs84",
    "PlanResult", "RouteSegment", "LoopRoute", "ScoreComponent", "ScoreResult",
    "CalibrateResult", "GenerateOptions", "Candidate", "GenerateResult",
    "MapPlanner", "AmapWalkingPlanner", "MockPlanner",
    "generate_ring", "build_loop", "calibrate",
    "distance_error_score", "closure_score", "repetition_ratio", "repetition_score",
    "score_route", "DEFAULT_WEIGHTS", "generate_candidates",
]
