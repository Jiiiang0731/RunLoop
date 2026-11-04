#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""server API 离线测试：限流/熔断/并发闸/错误脱敏/契约字段。

绝不触真实高德 API：generate 的成功/失败路径均以 monkeypatch 替身驱动，
参数错误路径在进入 planner 之前即返回。
"""
import json
import os
import sys
import types
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import backend.guard as guard_mod
import backend.server as server_mod
from backend.guard import ConcurrencyGate


def _post(client, path, payload, headers=None):
    return client.post(path, data=json.dumps(payload),
                       content_type="application/json", headers=headers or {})


class ServerApiBase(unittest.TestCase):
    def setUp(self):
        # 环境净化：默认生产模式、Key 走环境变量（不依赖本机 key 文件）
        self._saved_env = {k: os.environ.get(k) for k in
                           ("RUNLOOP_ENV", "RUNLOOP_AMAP_KEY")}
        os.environ.pop("RUNLOOP_ENV", None)
        os.environ["RUNLOOP_AMAP_KEY"] = "TEST-SECRET-KEY-DO-NOT-LEAK"
        self._saved_rules = guard_mod.DEFAULT_RULES
        self.app = server_mod.create_app()
        self.app.testing = True
        self.client = self.app.test_client()
        self.state = self.app.extensions["runloop_guard"]

    def tearDown(self):
        for k, v in self._saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        guard_mod.DEFAULT_RULES = self._saved_rules


class TestHealth(ServerApiBase):
    def test_health_contract(self):
        r = self.client.get("/api/health")
        self.assertEqual(r.status_code, 200)
        j = r.get_json()
        self.assertEqual(j["status"], "ok")
        self.assertEqual(j["service"], "runloop-route-api")
        self.assertEqual(j["version"], "0.5")
        self.assertEqual(j["env"], "production")   # RUNLOOP_ENV 未设 → 生产
        self.assertEqual(j["breaker"], "closed")
        self.assertIn("uptime_s", j)
        # health 不经过限流/熔断（before_request 直通）
        self.assertNotIn("TEST-SECRET", r.get_data(as_text=True))

    def test_unknown_path_json_404(self):
        r = self.client.get("/api/nope")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(r.get_json()["error_code"], "NOT_FOUND")

    def test_client_config_contract(self):
        r = self.client.get("/api/client-config")
        self.assertEqual(r.status_code, 200)
        j = r.get_json()
        self.assertTrue(j["success"])
        cfg = j["config"]
        self.assertEqual(cfg["service_version"], "0.5")
        self.assertEqual(cfg["announcement"], "")
        self.assertEqual(cfg["generate"]["max_api_calls"], 800)
        self.assertEqual(cfg["pois"]["radius"], 500)
        self.assertNotIn("TEST-SECRET", r.get_data(as_text=True))


class TestValidationAndMasking(ServerApiBase):
    def test_bad_target_400(self):
        r = _post(self.client, "/api/route/generate",
                  {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["error_code"], "BAD_TARGET")

    def test_bad_origin_400(self):
        r = _post(self.client, "/api/route/generate",
                  {"origin": {"lng": 999.0, "lat": 30.5}, "target_m": 5000})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["error_code"], "BAD_ORIGIN")

    def test_production_masks_exception_detail(self):
        r = _post(self.client, "/api/route/generate", {"origin": "not-a-dict"})
        self.assertEqual(r.status_code, 400)
        j = r.get_json()
        self.assertEqual(j["error"], "参数错误")     # 生产模式不回显异常细节
        self.assertNotIn("AttributeError", r.get_data(as_text=True))

    def test_secret_never_in_responses(self):
        for r in (self.client.get("/api/health"),
                  _post(self.client, "/api/route/generate", {"origin": {}}),
                  self.client.get("/api/nope")):
            self.assertNotIn("TEST-SECRET-KEY-DO-NOT-LEAK", r.get_data(as_text=True))

    def test_payload_too_large_413(self):
        big = {"origin": {"lng": 114.0, "lat": 30.5}, "blob": "x" * (300 * 1024)}
        r = _post(self.client, "/api/route/generate", big)
        self.assertEqual(r.status_code, 413)
        self.assertEqual(r.get_json()["error_code"], "PAYLOAD_TOO_LARGE")


class TestKeyMissing(ServerApiBase):
    def test_key_missing_500_without_leak(self):
        os.environ.pop("RUNLOOP_AMAP_KEY", None)
        server_mod._key_cache["key"] = None
        saved = server_mod.KEY_FILE
        server_mod.KEY_FILE = os.path.join(server_mod.ROOT, "config", "__no_such_key__")
        try:
            r = _post(self.client, "/api/route/generate",
                      {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 5000})
            self.assertEqual(r.status_code, 500)
            self.assertEqual(r.get_json()["error_code"], "KEY_MISSING")
        finally:
            server_mod.KEY_FILE = saved


class TestGuards(ServerApiBase):
    def test_rate_limited_429(self):
        guard_mod.DEFAULT_RULES = {"/api/route/generate": [(60, 2)]}
        app = server_mod.create_app()
        app.testing = True
        client = app.test_client()
        payload = {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999}  # 400 快速路径
        self.assertEqual(_post(client, "/api/route/generate", payload).status_code, 400)
        self.assertEqual(_post(client, "/api/route/generate", payload).status_code, 400)
        r = _post(client, "/api/route/generate", payload)
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.get_json()["error_code"], "RATE_LIMITED")
        self.assertIn("Retry-After", r.headers)
        # 不同设备标识不受牵连
        r2 = _post(client, "/api/route/generate", payload,
                   headers={"X-Device-Id": "other-device"})
        self.assertEqual(r2.status_code, 400)

    def test_xff_client_key_behind_proxy(self):
        """Tailscale Serve 反代（remote_addr=回环）时按 XFF 首址分桶。"""
        guard_mod.DEFAULT_RULES = {"/api/route/generate": [(60, 2)]}
        app = server_mod.create_app()
        app.testing = True
        client = app.test_client()
        payload = {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999}
        h_a = {"X-Forwarded-For": "100.64.0.2"}
        self.assertEqual(_post(client, "/api/route/generate", payload, headers=h_a).status_code, 400)
        self.assertEqual(_post(client, "/api/route/generate", payload, headers=h_a).status_code, 400)
        r = _post(client, "/api/route/generate", payload, headers=h_a)
        self.assertEqual(r.status_code, 429)          # 同一 Tailnet IP 触发配额
        r2 = _post(client, "/api/route/generate", payload,
                   headers={"X-Forwarded-For": "100.64.0.1"})
        self.assertEqual(r2.status_code, 400)          # 不同 XFF IP 不受牵连
        r3 = _post(client, "/api/route/generate", payload,
                   headers={"X-Forwarded-For": "100.64.0.2",
                            "X-Device-Id": "fresh-device"})
        self.assertEqual(r3.status_code, 400)          # X-Device-Id 优先于 XFF

    def test_xff_ignored_from_non_loopback(self):
        """非回环来源的 XFF 不可信（防御纵深）：按 remote_addr 分桶。"""
        guard_mod.DEFAULT_RULES = {"/api/route/generate": [(60, 2)]}
        app = server_mod.create_app()
        app.testing = True
        client = app.test_client()
        payload = json.dumps({"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999})
        base = {"REMOTE_ADDR": "10.1.2.3"}
        for xff in ("100.64.0.2", "100.64.0.1"):
            r = client.post("/api/route/generate", data=payload,
                            content_type="application/json",
                            headers={"X-Forwarded-For": xff},
                            environ_base=base)
            self.assertEqual(r.status_code, 400)
        # 第三个「伪装的 XFF」同样计入 10.1.2.3 的桶 → 429
        r = client.post("/api/route/generate", data=payload,
                        content_type="application/json",
                        headers={"X-Forwarded-For": "8.8.8.8"},
                        environ_base=base)
        self.assertEqual(r.status_code, 429)

    def test_breaker_open_503(self):
        for _ in range(3):
            self.state.breaker.record_throttle()
        self.assertEqual(self.state.breaker.state, "open")
        r = _post(self.client, "/api/route/generate",
                  {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999})
        self.assertEqual(r.status_code, 503)
        j = r.get_json()
        self.assertEqual(j["error_code"], "UPSTREAM_QUOTA")
        self.assertIn("Retry-After", r.headers)
        # health 仍可用（探活不被熔断拦截）
        self.assertEqual(self.client.get("/api/health").status_code, 200)

    def test_concurrency_gate_busy_429(self):
        gate = ConcurrencyGate(limits={"/api/route/generate": 1}, wait_s=0.01)
        self.assertTrue(gate.acquire("/api/route/generate"))  # 预占满
        self.state.gate = gate
        r = _post(self.client, "/api/route/generate",
                  {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999})
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.get_json()["error_code"], "SERVER_BUSY")
        gate.release("/api/route/generate")
        # 释放后恢复正常（并发闸不粘滞）
        r2 = _post(self.client, "/api/route/generate",
                   {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999})
        self.assertEqual(r2.status_code, 400)

    def test_gate_released_after_request(self):
        _post(self.client, "/api/route/generate",
              {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 999})
        sem = self.state.gate._sems["/api/route/generate"]
        # 请求结束（teardown）后信号量必须已归还
        self.assertEqual(sem._value, self.state.gate.limits["/api/route/generate"])


class TestGenerateFlow(ServerApiBase):
    """用替身驱动 generate 的 NO_ROUTE / 成功路径（零真实 HTTP）。"""

    def _patch_generator(self, candidates, total_calls=0):
        result = types.SimpleNamespace(candidates=candidates,
                                       total_api_calls=total_calls,
                                       stage_times={"calibrate": 1.0})
        self._saved_gen = server_mod.generate_candidates
        server_mod.generate_candidates = lambda *a, **k: result

    def tearDown(self):
        server_mod.generate_candidates = getattr(self, "_saved_gen",
                                                 server_mod.generate_candidates)
        super().tearDown()

    def test_no_route_200_contract(self):
        self._patch_generator([])
        r = _post(self.client, "/api/route/generate",
                  {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 5000})
        self.assertEqual(r.status_code, 200)
        j = r.get_json()
        self.assertFalse(j["success"])
        self.assertEqual(j["error_code"], "NO_ROUTE")
        self.assertEqual(j["target_m"], 5000)
        self.assertEqual(j["tol_m"], 500)
        self.assertNotIn("TEST-SECRET", r.get_data(as_text=True))

    def test_success_contract_and_breaker_reset(self):
        # 伪造一个达标候选（结构与真实 _serialize_candidate 输入一致）
        loop = types.SimpleNamespace(
            distance_m=5002.0, closure_m=0.5, start_snap_m=3.0, duration_s=1800.0,
            polyline=[(114.0, 30.5), (114.01, 30.5), (114.01, 30.51), (114.0, 30.5)],
            segments=[])
        cand = types.SimpleNamespace(seed=1, loop=loop, error=None, recommended=True,
                                     score=None, metrics={}, api_calls=5, elapsed_s=1.0,
                                     history=[])
        self._patch_generator([cand], total_calls=5)
        # 熔断器预置 half_open：成功候选应将其复位为 closed
        self.state.breaker.record_throttle()
        self.state.breaker.record_throttle()
        self.state.breaker.record_throttle()
        self.state.breaker._opened_at -= 200  # 冷却期满 → half_open
        self.assertEqual(self.state.breaker.state, "half_open")

        r = _post(self.client, "/api/route/generate",
                  {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 5000})
        self.assertEqual(r.status_code, 200)
        j = r.get_json()
        self.assertTrue(j["success"])
        self.assertEqual(j["target_m"], 5000)
        self.assertEqual(j["tol_m"], 500)
        c = j["candidates"][0]
        self.assertTrue(c["ok"])
        self.assertTrue(c["recommended"])
        self.assertEqual(c["error_m"], 2.0)
        self.assertTrue(c["within_tolerance"])
        self.assertTrue(c["closure_ok"])
        # 折线降采样 ×2（保留首尾）：4 点 → [p0, p2, p3]
        self.assertEqual(len(c["polyline"]), 3)
        self.assertEqual(c["polyline"][0], [114.0, 30.5])
        self.assertEqual(c["polyline"][-1], [114.0, 30.5])
        self.assertEqual(self.state.breaker.state, "closed", "成功候选应复位熔断器")

    def test_tol_clamped_to_500(self):
        """决策#1：客户端不得放宽容差——tol_m>500 被钳制回 500。"""
        self._patch_generator([])
        r = _post(self.client, "/api/route/generate",
                  {"origin": {"lng": 114.087, "lat": 30.536},
                   "target_m": 5000, "tol_m": 5000})
        self.assertEqual(r.get_json()["tol_m"], 500)

    def test_max_api_calls_clamped(self):
        """预算钳制在 (50, 1500)，默认 800。"""
        captured = {}

        def fake_gen(planner, origin, options):
            captured["max_calls"] = options.max_api_calls
            captured["fix_detours"] = options.fix_detours
            return types.SimpleNamespace(candidates=[], total_api_calls=0,
                                         stage_times={})
        self._saved_gen = server_mod.generate_candidates
        server_mod.generate_candidates = fake_gen
        _post(self.client, "/api/route/generate",
              {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 5000,
               "max_api_calls": 999999, "fix_detours": False})
        self.assertEqual(captured["max_calls"], 1500)
        self.assertFalse(captured["fix_detours"])
        _post(self.client, "/api/route/generate",
              {"origin": {"lng": 114.087, "lat": 30.536}, "target_m": 5000})
        self.assertEqual(captured["max_calls"], 800)
        self.assertTrue(captured["fix_detours"])


if __name__ == "__main__":
    unittest.main()
