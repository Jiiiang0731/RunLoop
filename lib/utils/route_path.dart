import 'package:amap_flutter_base/amap_flutter_base.dart';

import 'map_icons.dart';

/// 路线上的一个位置（含前进方向）。
class RoutePosition {
  final LatLng point;
  final double bearing;

  const RoutePosition(this.point, this.bearing);
}

/// 真实折线的累计距离索引，供「按距离驱动」的生长动画使用。
class RoutePath {
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
}
