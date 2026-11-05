#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路径规划器接口 + 高德真实实现 + 确定性 Mock（供单元测试）。"""
import json
import time
import urllib.parse
import urllib.request
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
        ck = (round(origin[0], 6), round(origin[1], 6),
              round(dest[0], 6), round(dest[1], 6))
        if ck in self._cache:
            return self._cache[ck]

        o = f"{origin[0]:.6f},{origin[1]:.6f}"
        d = f"{dest[0]:.6f},{dest[1]:.6f}"
        q = urllib.parse.urlencode({"origin": o, "destination": d, "key": self.key})
        url = f"{self.base}/v3/direction/walking?{q}"
        last = "unknown"
        result: PlanResult
        for attempt in range(self.retries + 1):
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
