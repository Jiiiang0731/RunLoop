#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""generator 编排层单元测试（用 MockPlanner，不联网）。"""
import unittest

from backend.route_generator import (
    GenerateOptions, MockPlanner, ScoreComponent, ScoreResult,
    generate_candidates, rank_candidates,
)
from backend.route_generator.types import Candidate, PlanResult


class AlwaysFailPlanner:
    def plan_walking(self, origin, dest):
        return PlanResult(error="no route")


def _mk_candidate(seed: int, total, error=None) -> Candidate:
    score = None
    if total is not None:
        score = ScoreResult(total=total, components=[
            ScoreComponent("turn_density", 50.0, 0.35, True, "x")], unavailable=[])
    return Candidate(seed=seed, loop=object(), score=score, api_calls=1,
                     elapsed_s=0.1, history=[], error=error)


class TestRankCandidates(unittest.TestCase):
    def test_sorts_by_score_and_marks_recommended(self):
        cs = [_mk_candidate(1, 40.0), _mk_candidate(2, 90.0),
              _mk_candidate(3, 60.0)]
        ranked = rank_candidates(cs)
        self.assertEqual([c.seed for c in ranked], [2, 3, 1])
        self.assertTrue(ranked[0].recommended)
        self.assertFalse(ranked[1].recommended)
        self.assertFalse(ranked[2].recommended)

    def test_failures_go_last(self):
        cs = [_mk_candidate(1, None, error="boom"), _mk_candidate(2, 50.0)]
        ranked = rank_candidates(cs)
        self.assertEqual([c.seed for c in ranked], [2, 1])
        self.assertTrue(ranked[0].recommended)
        self.assertFalse(ranked[1].recommended)

    def test_all_failed_no_recommended(self):
        cs = [_mk_candidate(1, None, error="a"), _mk_candidate(2, None, error="b")]
        ranked = rank_candidates(cs)
        self.assertFalse(any(c.recommended for c in ranked))

    def test_rerank_clears_old_flag(self):
        cs = [_mk_candidate(1, 40.0), _mk_candidate(2, 90.0)]
        rank_candidates(cs)
        cs.append(_mk_candidate(3, 95.0))
        ranked = rank_candidates(cs)
        self.assertEqual(ranked[0].seed, 3)
        self.assertEqual(sum(1 for c in ranked if c.recommended), 1)


class TestGenerator(unittest.TestCase):
    center = (121.5, 31.2)

    def test_two_candidates(self):
        opts = GenerateOptions(target_m=10000, seeds=[1, 2], n_points=8,
                               tol_m=500, max_iters=8, detour_factor=1.4, sleep_s=0)
        res = generate_candidates(MockPlanner(factor=1.4), self.center, opts)
        self.assertEqual(len(res.candidates), 2)
        for c in res.candidates:
            self.assertIsNotNone(c.loop)
            self.assertTrue(c.loop.ok)
            self.assertIsNotNone(c.score)
            self.assertIsNone(c.error)
        self.assertGreater(res.total_api_calls, 0)
        # 阶段 J：恰好一个推荐候选，且排在最前
        recs = [c for c in res.candidates if c.recommended]
        self.assertEqual(len(recs), 1)
        self.assertTrue(res.candidates[0].recommended)

    def test_max_candidates_stops_early(self):
        opts = GenerateOptions(target_m=10000, seeds=[1, 2, 3], n_points=8,
                               tol_m=500, max_iters=8, detour_factor=1.4,
                               sleep_s=0, max_candidates=1)
        res = generate_candidates(MockPlanner(factor=1.4), self.center, opts)
        self.assertEqual(len(res.candidates), 1)

    def test_failure_propagates(self):
        opts = GenerateOptions(target_m=10000, seeds=[1], n_points=8,
                               max_iters=3, detour_factor=1.4, sleep_s=0)
        res = generate_candidates(AlwaysFailPlanner(), self.center, opts)
        self.assertEqual(len(res.candidates), 1)
        self.assertIsNotNone(res.candidates[0].error)
        self.assertIsNone(res.candidates[0].score)

    def test_per_seed_budget_caps_calls(self):
        """单种子预算护栏：全失败时 api 调用不超过 per_seed_calls + 段数余量。"""
        opts = GenerateOptions(target_m=10000, seeds=[1], n_points=8,
                               max_iters=8, detour_factor=1.4, sleep_s=0,
                               per_seed_calls=5, max_api_calls=600)
        res = generate_candidates(AlwaysFailPlanner(), self.center, opts)
        self.assertLessEqual(res.total_api_calls, 5)


if __name__ == "__main__":
    unittest.main()
