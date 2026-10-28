#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路径规划器接口 + 高德真实实现 + 确定性 Mock（供单元测试）。"""
import json
import time
import urllib.parse
import urllib.request
from typing import List

from .geo import GeoPoint, haversine
from .types import PlanResult


def _to_num(v) -> float:
    """高德步行/驾车 API 的 distance/duration 为字符串，需安全转数值。"""
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def _parse_polyline_from_steps(steps) -> List[GeoPoint]:
    pts: List[GeoPoint] = []
    for s in steps:
        for chunk in (s.get("polyline") or "").split(";"):
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


class MapPlanner:
    """路径规划抽象接口，便于替换地图服务或注入 Mock。"""
    def plan_walking(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        raise NotImplementedError


class AmapWalkingPlanner(MapPlanner):
    """高德 Web 服务步行路径规划实现。密钥由外部注入，不硬编码。"""

    def __init__(self, key: str, base: str = "https://restapi.amap.com",
                 retries: int = 2, sleep: float = 0.2, timeout: int = 30):
        self.key = key
        self.base = base
        self.retries = retries
        self.sleep = sleep
        self.timeout = timeout

    def _http(self, url: str) -> dict:
        req = urllib.request.Request(url, headers={"User-Agent": "RunLoop/0.2"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def plan_walking(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        o = f"{origin[0]:.6f},{origin[1]:.6f}"
        d = f"{dest[0]:.6f},{dest[1]:.6f}"
        q = urllib.parse.urlencode({"origin": o, "destination": d, "key": self.key})
        url = f"{self.base}/v3/direction/walking?{q}"
        last = "unknown"
        for attempt in range(self.retries + 1):
            try:
                data = self._http(url)
            except Exception as e:  # noqa: BLE001
                last = f"exception:{type(e).__name__}"
                if attempt < self.retries:
                    time.sleep(self.sleep)
                    continue
                return PlanResult(error=last)
            if str(data.get("status")) == "1" and data.get("route") and data["route"].get("paths"):
                p = data["route"]["paths"][0]
                return PlanResult(
                    distance_m=_to_num(p.get("distance")),
                    duration_s=_to_num(p.get("duration")),
                    points=_parse_polyline_from_steps(p.get("steps", [])),
                )
            last = f"infocode={data.get('infocode')} info={data.get('info')}"
            if attempt < self.retries:
                time.sleep(self.sleep)
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

    def plan_walking(self, origin: GeoPoint, dest: GeoPoint) -> PlanResult:
        self.calls += 1
        straight = haversine(origin, dest)
        pts: List[GeoPoint] = []
        for k in range(self.n_samples + 1):
            t = k / self.n_samples
            pts.append((origin[0] + (dest[0] - origin[0]) * t,
                        origin[1] + (dest[1] - origin[1]) * t))
        distance = straight * self.factor
        return PlanResult(distance_m=distance, duration_s=distance / 1.25, points=pts)
