#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路径规划器接口 + 高德真实实现 + 确定性 Mock（供单元测试）。"""
import json
import os
import threading
import time
import urllib.parse
import urllib.request
from collections import OrderedDict
from typing import List

from .geo import GeoPoint, haversine
from .types import PlanResult, PlanStep

# 高德限流/配额类 infocode：命中时用更长退避重试（QPS 超限、日配额、并发超限）。
_THROTTLE_CODES = {
    "10003",  # DAILY_QUERY_OVER_LIMIT 日调用量超限
    "10004",  # ACCESS_TOO_FREQUENT 单位时间访问过于频繁
    "10019",  # CUQPS_HAS_EXCEEDED_THE_LIMIT
    "10020",  # CKQPS_HAS_EXCEEDED_THE_LIMIT
    "10021",  # CIQPS_HAS_EXCEEDED_THE_LIMIT
    "10022",  # QPS_HAS_EXCEEDED_THE_LIMIT
    "10023",  # QPS_HAS_EXCEEDED_THE_LIMIT_2
    "10044",  # 海外请求 QPS 超限
}


class _SharedPathCache:
    """阶段 Q：进程级成功步行路径缓存（TTL + LRU + in-flight 合并）。

    - 键：起终点经纬度各自保留 6 位小数（≈0.11m），方向敏感——绝不假设
      A→B 与 B→A 相同；
    - 只缓存 error is None 的成功结果；失败请求绝不入缓存；
    - 默认 TTL 600s、最多 2048 条；可用环境变量覆盖；
    - 同时只允许一个线程真正请求同一个键，其余等待并复用结果。
    """

    def __init__(self, ttl_s: float = 600.0, maxsize: int = 2048):
        self.ttl = max(10.0, ttl_s)
        self.maxsize = max(64, maxsize)
        self._lock = threading.Lock()
        self._data = OrderedDict()  # key -> (expire_at, PlanResult)
        self._inflight = {}         # key -> threading.Event
        self.hits = 0
        self.misses = 0
        self.evictions = 0
        self.waits = 0

    def get(self, key):
        now = time.monotonic()
        with self._lock:
            item = self._data.get(key)
            if item is not None:
                if item[0] > now:
                    self._data.move_to_end(key)
                    self.hits += 1
                    return item[1]
                self._data.pop(key, None)
            self.misses += 1
            return None

    def put(self, key, value):
        with self._lock:
            self._data[key] = (time.monotonic() + self.ttl, value)
            self._data.move_to_end(key)
            while len(self._data) > self.maxsize:
                self._data.popitem(last=False)
                self.evictions += 1

    def begin(self, key):
        """返回 (is_owner, event)。非 owner 应等待 event 后重查缓存。"""
        with self._lock:
            ev = self._inflight.get(key)
            if ev is not None:
                self.waits += 1
                return False, ev
            ev = threading.Event()
            self._inflight[key] = ev
            return True, ev

    def end(self, key, event):
        with self._lock:
            if self._inflight.get(key) is event:
                self._inflight.pop(key, None)
        event.set()

    def stats(self):
        with self._lock:
            return {
                "hits": self.hits, "misses": self.misses,
                "evictions": self.evictions, "waits": self.waits,
                "size": len(self._data), "ttl_s": self.ttl,
                "maxsize": self.maxsize,
            }

    def clear(self):
        with self._lock:
            self._data.clear()
            self._inflight.clear()


class _TokenBucket:
    """全局 QPS 令牌桶（默认 3/s，稳妥低于当前实测触发 10021 的速率）。

    高德个人 Key 的 QPS 是全局稀缺资源；服务端并发闸 2 个请求共享此桶。
    只控制“HTTP 尝试”的启动速率，不控制重试退避。
    """

    def __init__(self, rate: float = 3.0, capacity: float = 1.0):
        self.rate = max(0.5, float(rate))
        self.capacity = max(1.0, float(capacity))
        self.tokens = self.capacity
        self.last = time.monotonic()
        self._lock = threading.Lock()

    def acquire(self):
        while True:
            with self._lock:
                now = time.monotonic()
                self.tokens = min(self.capacity,
                                  self.tokens + (now - self.last) * self.rate)
                self.last = now
                if self.tokens >= 1.0:
                    self.tokens -= 1.0
                    return
                wait = (1.0 - self.tokens) / self.rate
            time.sleep(min(max(wait, 0.005), 0.5))


_WALK_CACHE = _SharedPathCache(
    ttl_s=float(os.environ.get("RUNLOOP_WALK_CACHE_TTL_S", "600")),
    maxsize=int(os.environ.get("RUNLOOP_WALK_CACHE_SIZE", "2048")),
)
_AMAP_QPS = _TokenBucket(
    rate=float(os.environ.get("RUNLOOP_AMAP_QPS", "3.0")),
    capacity=1.0,
)


def walk_cache_stats():
    """供健康检查/诊断页观察缓存效果（不含坐标与密钥）。"""
    return _WALK_CACHE.stats()


def _to_num(v) -> float:
    """高德步行/驾车 API 的 distance/duration 为字符串，需安全转数值。"""
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def _parse_polyline(chunks_str: str) -> List[GeoPoint]:
    pts: List[GeoPoint] = []
    for chunk in (chunks_str or "").split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = chunk.split(",")
        if len(parts) == 2:
            try:
                pts.append((float(parts[0]), float(parts[1])))
            except ValueError:
                pass
    return pts


def _parse_polyline_from_steps(steps) -> List[GeoPoint]:
    pts: List[GeoPoint] = []
    for s in steps:
        pts.extend(_parse_polyline(s.get("polyline") or ""))
    return pts


def _parse_steps(raw_steps) -> List[PlanStep]:
    """解析高德 steps：保留 instruction/road/distance/action/orientation/polyline。"""
    out: List[PlanStep] = []
    for s in raw_steps or []:
        out.append(PlanStep(
            instruction=str(s.get("instruction") or ""),
            road=str(s.get("road") or ""),
            distance_m=_to_num(s.get("distance")),
            duration_s=_to_num(s.get("duration")),
            action=str(s.get("action") or ""),
            orientation=str(s.get("orientation") or ""),
            polyline=_parse_polyline(s.get("polyline") or ""),
            walk_type=str(s.get("walk_type") or ""),
        ))
    return out


class MapPlanner:
    """路径规划抽象接口，便于替换地图服务或注入 Mock。"""

    def plan_walking(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        raise NotImplementedError

    def plan_driving(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        """可选能力：驾车可通行性核验（阶段 N 的辅助指标，不是安全）。"""
        raise NotImplementedError

    @property
    def http_calls(self) -> int:
        """真实 HTTP 请求次数（不含缓存命中）。"""
        return 0


class AmapWalkingPlanner(MapPlanner):
    """高德 Web 服务步行路径规划实现。密钥由外部注入，不硬编码。

    带分段结果缓存：相同 (origin, destination) 命中缓存不消耗配额。
    """

    def __init__(self, key: str, base: str = "https://restapi.amap.com",
                 retries: int = 3, sleep: float = 0.25, timeout: int = 30,
                 cache_size: int = 4096):
        self.key = key
        self.base = base
        self.retries = retries
        self.sleep = sleep
        self.timeout = timeout
        self._cache: dict = {}
        self._drive_cache: dict = {}
        self._cache_size = cache_size
        self._http_calls = 0

    @property
    def http_calls(self) -> int:
        return self._http_calls

    def _http(self, url: str) -> dict:
        req = urllib.request.Request(url, headers={"User-Agent": "RunLoop/0.3"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def wait_budget(self, max_calls: int) -> bool:
        """是否还有 HTTP 调用预算。"""
        return self._http_calls < max_calls

    def plan_walking(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        """带进程级成功缓存 + in-flight 合并的步行规划入口。"""
        ck = (round(origin[0], 6), round(origin[1], 6),
              round(dest[0], 6), round(dest[1], 6))
        if ck in self._cache:
            return self._cache[ck]
        cached = _WALK_CACHE.get(ck)
        if cached is not None:
            self._cache[ck] = cached
            return cached

        owner, ev = _WALK_CACHE.begin(ck)
        if not owner:
            # 同键请求已在飞：等它完成，直接复用成功结果（失败不入缓存）。
            ev.wait(timeout=max(5.0, self.timeout * (self.retries + 1) + 5.0))
            cached = _WALK_CACHE.get(ck)
            if cached is not None:
                self._cache[ck] = cached
                return cached
            # 前一个失败：自己再抢一次 owner；抢不到就直接请求一次。
            owner, ev = _WALK_CACHE.begin(ck)
            if not owner:
                cached = _WALK_CACHE.get(ck)
                if cached is not None:
                    self._cache[ck] = cached
                    return cached

        try:
            result = self._plan_walking_http(origin, dest, ck)
            if result.error is None:
                _WALK_CACHE.put(ck, result)
                self._cache[ck] = result
            return result
        finally:
            if owner:
                _WALK_CACHE.end(ck, ev)

    def _plan_walking_http(self, origin: GeoPoint, dest: GeoPoint,
                           ck) -> PlanResult:
        o = f"{origin[0]:.6f},{origin[1]:.6f}"
        d = f"{dest[0]:.6f},{dest[1]:.6f}"
        q = urllib.parse.urlencode({"origin": o, "destination": d, "key": self.key})
        url = f"{self.base}/v3/direction/walking?{q}"
        last = "unknown"
        result: PlanResult
        for attempt in range(self.retries + 1):
            # 阶段 Q：全局令牌桶控制 QPS（含重试）；默认 3/s，低于实测触发
            # 10021 的速率。固定 per-segment sleep 由 server 默认改为 0。
            _AMAP_QPS.acquire()
            self._http_calls += 1
            # 指数退避：0.25s → 0.5s → 1s（QPS 限流/瞬时故障恢复实测有效）
            backoff = self.sleep * (2 ** attempt)
            try:
                data = self._http(url)
            except Exception as e:  # noqa: BLE001
                last = f"exception:{type(e).__name__}"
                if attempt < self.retries:
                    time.sleep(backoff)
                    continue
                return PlanResult(error=last)
            if str(data.get("status")) == "1" and data.get("route") and data["route"].get("paths"):
                p = data["route"]["paths"][0]
                raw_steps = p.get("steps", [])
                result = PlanResult(
                    distance_m=_to_num(p.get("distance")),
                    duration_s=_to_num(p.get("duration")),
                    points=_parse_polyline_from_steps(raw_steps),
                    steps=_parse_steps(raw_steps),
                )
                if len(self._cache) >= self._cache_size:
                    self._cache.clear()
                self._cache[ck] = result
                return result
            last = f"infocode={data.get('infocode')} info={data.get('info')}"
            if attempt < self.retries:
                # 限流类 infocode（QPS/配额）用更长退避，其余按常规退避
                code = str(data.get("infocode") or "")
                time.sleep(backoff * (2.0 if code in _THROTTLE_CODES else 1.0))
                continue
            return PlanResult(error=last)
        return PlanResult(error=last)

    def plan_driving(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        """高德驾车 v5：只用于「机动车可通行性」辅助核验。

        与步行共用 Key/缓存/预算；返回真实距离与 steps，不推断车流或安全。
        """
        ck = (round(origin[0], 6), round(origin[1], 6),
              round(dest[0], 6), round(dest[1], 6))
        if ck in self._drive_cache:
            return self._drive_cache[ck]

        q = urllib.parse.urlencode({
            "origin": f"{origin[0]:.6f},{origin[1]:.6f}",
            "destination": f"{dest[0]:.6f},{dest[1]:.6f}",
            "key": self.key,
        })
        url = f"{self.base}/v5/direction/driving?{q}"
        last = "unknown"
        for attempt in range(self.retries + 1):
            _AMAP_QPS.acquire()
            self._http_calls += 1
            backoff = self.sleep * (2 ** attempt)
            try:
                data = self._http(url)
            except Exception as e:  # noqa: BLE001
                last = f"exception:{type(e).__name__}"
                if attempt < self.retries:
                    time.sleep(backoff)
                    continue
                return PlanResult(error=last)
            if str(data.get("status")) == "1":
                paths = (data.get("route") or {}).get("paths") or []
                if paths:
                    p = paths[0]
                    raw_steps = p.get("steps", [])
                    result = PlanResult(
                        distance_m=_to_num(p.get("distance")),
                        duration_s=_to_num(p.get("duration")),
                        points=_parse_polyline_from_steps(raw_steps),
                        steps=_parse_steps(raw_steps),
                    )
                    if len(self._drive_cache) >= self._cache_size:
                        self._drive_cache.clear()
                    self._drive_cache[ck] = result
                    return result
            last = f"infocode={data.get('infocode')} info={data.get('info')}"
            if attempt < self.retries:
                code = str(data.get("infocode") or "")
                time.sleep(backoff * (2.0 if code in _THROTTLE_CODES else 1.0))
                continue
            return PlanResult(error=last)
        return PlanResult(error=last)


class MockPlanner(MapPlanner):
    """确定性模拟规划器：distance = 直线距离 * factor，折线为直线插值。

    用于单元测试，不联网、不消耗配额；行为可完全预测。
    """

    def __init__(self, factor: float = 1.4, n_samples: int = 12):
        self.factor = factor
        self.n_samples = n_samples
        self.calls = 0

    @property
    def http_calls(self) -> int:
        return self.calls

    def plan_walking(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        self.calls += 1
        straight = haversine(origin, dest)
        pts: List[GeoPoint] = []
        for k in range(self.n_samples + 1):
            t = k / self.n_samples
            pts.append((origin[0] + (dest[0] - origin[0]) * t,
                        origin[1] + (dest[1] - origin[1]) * t))
        distance = straight * self.factor
        return PlanResult(distance_m=distance, duration_s=distance / 1.25, points=pts,
                          steps=[PlanStep(instruction="直行", road="测试路",
                                          distance_m=distance, polyline=pts)])

    def plan_driving(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        self.calls += 1
        straight = haversine(origin, dest)
        pts: List[GeoPoint] = [origin, dest]
        distance = straight * 1.05
        return PlanResult(distance_m=distance, duration_s=distance / 8.0, points=pts,
                          steps=[PlanStep(instruction="直行", road="测试路",
                                          distance_m=distance, polyline=pts)])
