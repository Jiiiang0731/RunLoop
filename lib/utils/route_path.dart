import 'dart:math' as math;

import 'package:amap_flutter_base/amap_flutter_base.dart';

import 'map_icons.dart';

/// 路线上的一个位置（含前进方向）。
class RoutePosition {
  final LatLng point;
  final double bearing;

  const RoutePosition(this.point, this.bearing);
}

/// 某点在路线上的投影结果（阶段 J：跑步页进度/偏航检测）。
class RouteProjection {
  /// 起点沿路线到投影点的累计距离（米）。
  final double alongM;

  /// 点到路线的垂距（米）——偏航判断依据。
  final double offsetM;

  /// 投影点本身。
  final LatLng point;

  const RouteProjection(this.alongM, this.offsetM, this.point);
}

/// 真实折线的累计距离索引，供「按距离驱动」的生长动画使用。
class RoutePath {
  /// 投影平局容差（米）：垂距差在此范围内视为「一样近」，
  /// 由里程提示决定归属（去/返程完全重叠时不串腿）。
  static const double _kTieM = 0.5;

  final List<LatLng> points;
  final List<double> cum; // cum[i] = 起点到第 i 个点的累计距离（米）
  final double total;

  RoutePath._(this.points, this.cum, this.total);

  factory RoutePath.fromPoints(List<LatLng> points) {
    final List<double> cum = <double>[0];
    double total = 0;
    for (int i = 1; i < points.length; i++) {
      total += haversineMeters(points[i - 1], points[i]);
      cum.add(total);
    }
    return RoutePath._(points, cum, total);
  }

  /// 距离 [d]（米）处的位置与前进方向（沿真实折线插值）。
  RoutePosition at(double d) {
    if (points.isEmpty) return const RoutePosition(LatLng(0, 0), 0);
    if (points.length == 1) return RoutePosition(points.first, 0);
    final double dist = d.clamp(0.0, total);
    int i = 0;
    while (i < cum.length - 1 && cum[i + 1] < dist) {
      i++;
    }
    if (i >= points.length - 1) {
      return RoutePosition(
        points.last,
        bearingDeg(points[points.length - 2], points.last),
      );
    }
    final double segStart = cum[i];
    final double segLen = cum[i + 1] - segStart;
    final double t = segLen <= 0 ? 0 : (dist - segStart) / segLen;
    final LatLng a = points[i];
    final LatLng b = points[i + 1];
    final LatLng pos = LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
    return RoutePosition(pos, bearingDeg(a, b));
  }

  /// 距离 [d] 之前的折线（含插值终点），用于「生长」绘制。
  List<LatLng> upTo(double d) {
    if (points.isEmpty) return <LatLng>[];
    if (points.length == 1) return <LatLng>[points.first];
    final double dist = d.clamp(0.0, total);
    final List<LatLng> out = <LatLng>[points.first];
    for (int i = 1; i < points.length; i++) {
      if (cum[i] <= dist) {
        out.add(points[i]);
      } else {
        final double segStart = cum[i - 1];
        final double segLen = cum[i] - segStart;
        final double t = segLen <= 0 ? 0 : (dist - segStart) / segLen;
        // 距离恰好落在已有点上时，不再追加重复的插值点。
        if (t > 1e-9) {
          final LatLng a = points[i - 1];
          final LatLng b = points[i];
          out.add(LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          ));
        }
        break;
      }
    }
    return out;
  }

  /// 距离 [d] 之后的折线（含插值起点），用于跑步页「剩余路线」绘制
  /// （阶段 L 模块 E：与 [upTo] 互补，两者共享插值点保证首尾衔接）。
  List<LatLng> fromDistance(double d) {
    if (points.isEmpty) return <LatLng>[];
    if (points.length == 1) return <LatLng>[points.first];
    final double dist = d.clamp(0.0, total);
    final List<LatLng> out = <LatLng>[];
    for (int i = 1; i < points.length; i++) {
      if (cum[i] <= dist) continue; // 该点已在跑过的部分
      if (out.isEmpty) {
        // 第一个未越过的段：先补 [d] 处的插值起点（除非恰落在点上）
        final double segStart = cum[i - 1];
        final double segLen = cum[i] - segStart;
        final double t = segLen <= 0 ? 0 : (dist - segStart) / segLen;
        if (t > 1e-9) {
          final LatLng a = points[i - 1];
          final LatLng b = points[i];
          out.add(LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          ));
        } else {
          out.add(points[i - 1]);
        }
      }
      out.add(points[i]);
    }
    if (out.isEmpty) out.add(points.last);
    return out;
  }

  /// 把任意点 [p] 投影到折线上（全局最近）：返回沿线里程、垂距与投影点。
  ///
  /// 局部平面近似（纬度方向 1° ≈ 111km，经度按 cos(lat) 收缩），
  /// 对城市尺度（<50km）误差可忽略；逐段扫描 O(N)。
  RouteProjection project(LatLng p) => _scan(p, 0, points.length - 2);

  /// 窗口化投影：只在 [hintAlong]±[windowM] 的里程范围内找最近点。
  ///
  /// 环线的去/返程腿可能只相隔 10~20m（阶段 G 视觉偏移前），全局最近投影
  /// 会把跑者「吸附」到错误的腿上。用上一次投影里程作提示做局部搜索，
  /// 即可稳定跟踪当前腿；跑出窗口（抄近路/重新汇入）时由调用方回退全局投影。
  RouteProjection projectNear(LatLng p, double? hintAlong, double windowM) {
    if (hintAlong == null || points.length < 3) return project(p);
    final double lo = (hintAlong - windowM).clamp(0.0, total);
    final double hi = (hintAlong + windowM).clamp(0.0, total);
    int i0 = 0;
    while (i0 < points.length - 2 && cum[i0 + 1] < lo) {
      i0++;
    }
    int i1 = i0;
    while (i1 < points.length - 2 && cum[i1] < hi) {
      i1++;
    }
    return _scan(p, i0, i1, hint: hintAlong);
  }

  RouteProjection _scan(LatLng p, int i0, int i1, {double? hint}) {
    if (points.isEmpty) return RouteProjection(0, double.infinity, p);
    if (points.length == 1 || i1 < i0) {
      return RouteProjection(0, haversineMeters(p, points.first), points.first);
    }
    final double cosLat = math.cos(p.latitude * math.pi / 180);
    final double px = p.longitude * cosLat;
    final double py = p.latitude;
    double bestAlong = cum[i0];
    double bestOffset = double.infinity;
    LatLng bestPoint = points[i0];
    for (int i = i0; i <= i1; i++) {
      final LatLng a = points[i];
      final LatLng b = points[i + 1];
      final double ax = a.longitude * cosLat;
      final double ay = a.latitude;
      final double dx = b.longitude * cosLat - ax;
      final double dy = b.latitude - ay;
      final double len2 = dx * dx + dy * dy;
      double t = len2 <= 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / len2;
      t = t.clamp(0.0, 1.0);
      final LatLng proj = LatLng(ay + dy * t, (ax + dx * t) / cosLat);
      final double off = haversineMeters(p, proj);
      final double along = cum[i] + (cum[i + 1] - cum[i]) * t;
      bool better;
      if (hint == null) {
        better = off < bestOffset; // 全局：纯几何最近，平局取先出现者
      } else if (off < bestOffset - _kTieM) {
        better = true; // 明显更近
      } else if (off <= bestOffset + _kTieM) {
        // 垂距几乎相同（去/返程完全重叠）→ 取里程更接近提示者，避免串腿
        better = (along - hint).abs() < (bestAlong - hint).abs();
      } else {
        better = false;
      }
      if (better) {
        bestOffset = off;
        bestPoint = proj;
        bestAlong = along;
      }
    }
    return RouteProjection(bestAlong, bestOffset, bestPoint);
  }
}
