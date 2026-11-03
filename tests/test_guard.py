#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""guard（限流/并发闸/熔断/脱敏）单元测试：全部离线，假时钟驱动。"""
import sys
import os
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.guard import (
    CircuitBreaker, ConcurrencyGate, RateLimiter,
    hash_device, looks_throttled, sanitize_origin,
)


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t += dt


class TestRateLimiter(unittest.TestCase):
    def test_window_limit_and_reset(self):
        clk = FakeClock()
        rl = RateLimiter(rules={"/x": [(60, 2)]}, clock=clk)
        self.assertEqual(rl.check("/x", "dev1"), (True, 0))
        self.assertEqual(rl.check("/x", "dev1"), (True, 0))
        ok, retry = rl.check("/x", "dev1")
        self.assertFalse(ok)
        self.assertGreater(retry, 0)
        clk.advance(61)
        self.assertEqual(rl.check("/x", "dev1"), (True, 0))

    def test_per_device_isolation(self):
        clk = FakeClock()
        rl = RateLimiter(rules={"/x": [(60, 1)]}, clock=clk)
        self.assertTrue(rl.check("/x", "dev1")[0])
        self.assertFalse(rl.check("/x", "dev1")[0])
        self.assertTrue(rl.check("/x", "dev2")[0], "不同设备互不影响")

    def test_multi_window_stacking(self):
        clk = FakeClock()
        rl = RateLimiter(rules={"/x": [(60, 2), (3600, 3)]}, clock=clk)
        self.assertTrue(rl.check("/x", "d")[0])
        self.assertTrue(rl.check("/x", "d")[0])
        self.assertFalse(rl.check("/x", "d")[0])   # 分钟窗口先拦
        clk.advance(61)
        self.assertTrue(rl.check("/x", "d")[0])    # 第 3 次（小时窗口内）
        ok, retry = rl.check("/x", "d")
        self.assertFalse(ok)                        # 小时窗口拦截
        self.assertLessEqual(retry, 3600)
        self.assertGreater(retry, 3400)

    def test_unconfigured_path_passes(self):
        rl = RateLimiter(rules={})
        self.assertEqual(rl.check("/api/health", "d"), (True, 0))

    def test_prune_removes_stale_keys(self):
        clk = FakeClock()
        rl = RateLimiter(rules={"/x": [(60, 5)]}, clock=clk)
        rl.check("/x", "d1")
        rl.check("/x", "d2")
        clk.advance(100000)
        rl.prune(max_age_s=90000)
        self.assertEqual(rl._hits, {})


class TestCircuitBreaker(unittest.TestCase):
    def test_open_halfopen_closed_cycle(self):
        clk = FakeClock()
        cb = CircuitBreaker(threshold=2, cooldown_s=100, clock=clk)
        self.assertEqual(cb.state, "closed")
        cb.record_throttle()
        self.assertEqual(cb.state, "closed")        # 未到阈值
        self.assertTrue(cb.allow()[0])
        cb.record_throttle()
        self.assertEqual(cb.state, "open")
        ok, retry = cb.allow()
        self.assertFalse(ok)
        self.assertGreaterEqual(retry, 99)
        clk.advance(100)
        self.assertEqual(cb.state, "half_open")
        self.assertTrue(cb.allow()[0])              # 半开放行探测
        cb.record_success()
        self.assertEqual(cb.state, "closed")

    def test_success_resets_consecutive(self):
        clk = FakeClock()
        cb = CircuitBreaker(threshold=2, cooldown_s=100, clock=clk)
        cb.record_throttle()
        cb.record_success()
        cb.record_throttle()
        self.assertEqual(cb.state, "closed", "成功后计数应清零")

    def test_throttle_failure_while_halfopen_reopens(self):
        clk = FakeClock()
        cb = CircuitBreaker(threshold=1, cooldown_s=50, clock=clk)
        cb.record_throttle()
        clk.advance(50)
        self.assertEqual(cb.state, "half_open")
        self.assertTrue(cb.allow()[0])   # 半开放行探测
        cb.record_throttle()             # 探测又撞限流 → 重新打开并重置冷却
        self.assertEqual(cb.state, "open")
        ok, retry = cb.allow()
        self.assertFalse(ok)
        self.assertGreaterEqual(retry, 49)


class TestConcurrencyGate(unittest.TestCase):
    def test_limit_and_release(self):
        gate = ConcurrencyGate(limits={"/g": 1}, wait_s=0.01)
        self.assertTrue(gate.acquire("/g"))
        self.assertFalse(gate.acquire("/g"))
        gate.release("/g")
        self.assertTrue(gate.acquire("/g"))
        gate.release("/g")

    def test_unconfigured_path(self):
        gate = ConcurrencyGate(limits={})
        self.assertTrue(gate.acquire("/anything"))
        gate.release("/anything")  # 不应抛异常


class TestSanitizers(unittest.TestCase):
    def test_hash_device(self):
        h1 = hash_device("device-uuid-A")
        h2 = hash_device("device-uuid-B")
        self.assertEqual(len(h1), 8)
        self.assertEqual(h1, hash_device("device-uuid-A"))
        self.assertNotEqual(h1, h2)
        self.assertNotIn("device-uuid-A", h1)

    def test_sanitize_origin(self):
        self.assertEqual(sanitize_origin(114.087279, 30.536395), "114.09,30.54")
        self.assertEqual(sanitize_origin(None, 30.5), "-")

    def test_looks_throttled(self):
        self.assertTrue(looks_throttled("infocode=10003 info=请求 too frequent"))
        self.assertTrue(looks_throttled("xxx 10044 yyy"))
        self.assertFalse(looks_throttled("infocode=10001 info=key不正确"))
        self.assertFalse(looks_throttled(None))
        self.assertFalse(looks_throttled(""))


if __name__ == "__main__":
    unittest.main()
