#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""服务端防护（阶段 K 第七/十部分）：限流、并发闸、熔断器、日志脱敏。

设计约束：
- 单进程内存实现（waitress 单实例部署，无 Redis 依赖）；
- 客户端标识 = X-Device-Id 头（App 每安装生成的 UUID）或远端 IP
  （Tailnet 内 100.x 地址稳定）——轻量设备配额，不是共享口令；
- 高德 Web Key 是全局稀缺资源（个人 15 万次/月、QPS 有限），
  限流/熔断的第一目标是保护 Key 配额，其次才是保护本机 CPU；
- 日志脱敏：设备号只记 sha256 前 8 位，坐标只记 2 位小数（~1km 网格），
  绝不落 Key、绝不落完整轨迹/折线。

全部类可离线单测（tests/test_guard.py）。
"""
import hashlib
import threading
import time
from typing import Dict, List, Optional, Tuple

# 高德限流/配额类 infocode（与 route_generator.planner._THROTTLE_CODES 同源语义）
THROTTLE_CODES = {"10003", "10004", "10019", "10020", "10021", "10022",
                  "10023", "10044"}

# 每端点限流规则：路径 -> [(窗口秒, 窗口内最大次数), ...]（全部满足才放行）
DEFAULT_RULES: Dict[str, List[Tuple[int, int]]] = {
    # 生成一次路线 ≈ 20~200 次高德调用、5~60s 计算——最贵的端点
    "/api/route/generate": [(600, 8), (86400, 80)],
    # POI 查询每次 ~18 个高德调用，但结果有 1h 服务端缓存
    "/api/route/pois": [(3600, 30)],
}


def hash_device(device_id: str) -> str:
    """设备标识脱敏：sha256 前 8 位（日志/审计用，不可逆推原值）。"""
    return hashlib.sha256((device_id or "").encode("utf-8")).hexdigest()[:8]


def sanitize_origin(lng: Optional[float], lat: Optional[float]) -> str:
    """坐标脱敏：保留 2 位小数（~1.1km×0.9km 网格），足够排障、不足以追踪。"""
    if lng is None or lat is None:
        return "-"
    return f"{lng:.2f},{lat:.2f}"


class RateLimiter:
    """滑动窗口限流（每设备 × 每端点，多窗口叠加）。"""

    def __init__(self, rules: Optional[Dict[str, List[Tuple[int, int]]]] = None,
                 clock=time.monotonic):
        self.rules = rules if rules is not None else DEFAULT_RULES
        self._clock = clock
        self._hits: Dict[str, List[float]] = {}
        self._lock = threading.Lock()

    def check(self, path: str, device_key: str) -> Tuple[bool, int]:
        """返回 (allowed, retry_after_s)。未配置规则的路径直接放行。"""
        rules = self.rules.get(path)
        if not rules:
            return True, 0
        now = self._clock()
        store_key = f"{device_key}|{path}"
        with self._lock:
            # 只保留最长窗口的记录
            max_win = max(w for w, _ in rules)
            hist = [t for t in self._hits.get(store_key, ()) if now - t < max_win]
            for win, limit in rules:
                recent = [t for t in hist if now - t < win]
                if len(recent) >= limit:
                    retry = int(win - (now - recent[0])) + 1
                    self._hits[store_key] = hist
                    return False, max(1, retry)
            hist.append(now)
            self._hits[store_key] = hist
            return True, 0

    def prune(self, max_age_s: int = 90000) -> None:
        """清理长期不活跃的键（防内存缓慢增长；日窗口需保留 ~25h）。"""
        now = self._clock()
        with self._lock:
            dead = [k for k, v in self._hits.items()
                    if not v or now - v[-1] > max_age_s]
            for k in dead:
                self._hits.pop(k, None)


class CircuitBreaker:
    """高德配额熔断器：连续 throttle 失败达到阈值 → 打开（快速失败），
    冷却后半开（放行探测），成功即关闭。

    保护目标：高德日配额被打穿后（10003/10044），继续重试只会加速耗尽
    月配额并拖慢所有请求；熔断让客户端立刻得到明确的 503 + Retry-After。
    """

    def __init__(self, threshold: int = 3, cooldown_s: float = 120.0,
                 clock=time.monotonic):
        self.threshold = threshold
        self.cooldown_s = cooldown_s
        self._clock = clock
        self._consecutive = 0
        self._opened_at: Optional[float] = None
        self._lock = threading.Lock()

    @property
    def state(self) -> str:
        with self._lock:
            if self._opened_at is None:
                return "closed"
            if self._clock() - self._opened_at >= self.cooldown_s:
                return "half_open"
            return "open"

    def allow(self) -> Tuple[bool, int]:
        """是否放行请求；不放行时返回建议 Retry-After 秒。"""
        with self._lock:
            if self._opened_at is None:
                return True, 0
            elapsed = self._clock() - self._opened_at
            if elapsed >= self.cooldown_s:
                return True, 0  # 半开：放行探测请求
            return False, int(self.cooldown_s - elapsed) + 1

    def record_throttle(self) -> None:
        with self._lock:
            self._consecutive += 1
            if self._consecutive >= self.threshold:
                # 首次打开或半开探测再次失败 → (重新)开始冷却计时，
                # 否则半开态会无限放行探测请求，失去配额保护作用。
                self._opened_at = self._clock()

    def record_success(self) -> None:
        with self._lock:
            self._consecutive = 0
            self._opened_at = None


class ConcurrencyGate:
    """端点并发闸（信号量 + 短排队超时）。

    生成端点并发=2：高德个人 Key QPS 有限（单请求内串行调用），
    并发 2 已能打满合理吞吐，再多只会互相触发 10019/10020 限流。
    """

    def __init__(self, limits: Optional[Dict[str, int]] = None,
                 wait_s: float = 3.0):
        self.limits = limits if limits is not None else {
            "/api/route/generate": 2,
            "/api/route/pois": 4,
        }
        self.wait_s = wait_s
        self._sems: Dict[str, threading.Semaphore] = {
            p: threading.Semaphore(n) for p, n in self.limits.items()
        }

    def acquire(self, path: str) -> bool:
        sem = self._sems.get(path)
        if sem is None:
            return True
        return sem.acquire(timeout=self.wait_s)

    def release(self, path: str) -> None:
        sem = self._sems.get(path)
        if sem is not None:
            sem.release()


def looks_throttled(error_text: Optional[str]) -> bool:
    """错误串是否命中高德限流/配额 infocode（planner 错误格式 infocode=XXXXX）。"""
    if not error_text:
        return False
    return any(code in error_text for code in THROTTLE_CODES)
