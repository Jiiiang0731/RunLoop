import 'dart:math' as math;

import '../models/track_point.dart';

/// 当前跑步方向估计（阶段 Q）。
///
/// 数据源优先级（任务书 3.3）：
/// 1. 最近若干可靠 GPS 点的连续位移（最稳定，首选）；
/// 2. 单个 GPS 点的原生 bearing（仅速度足够时，低置信度兜底）；
/// 3. 最近一次可靠方向（短暂停止/GPS 差时，明确标注 frozen/age）。
///
/// 绝不把手机指南针或原路线下一段切线当作“用户当前前进方向”。
class HeadingEstimate {
  const HeadingEstimate({
    required this.heading,
    required this.source,
    required this.confidence,
    required this.ageMs,
  });

  final double? heading;
  final String source; // recent_points / gps_course / frozen / none
  final double confidence;
  final int ageMs;

  bool get reliable => heading != null && confidence >= 0.35;

  static const HeadingEstimate none =
      HeadingEstimate(heading: null, source: 'none', confidence: 0, ageMs: 0);
}

double _bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final double rlat1 = lat1 * math.pi / 180;
  final double rlat2 = lat2 * math.pi / 180;
  final double dlon = (lng2 - lng1) * math.pi / 180;
  final double y = math.sin(dlon) * math.cos(rlat2);
  final double x = math.cos(rlat1) * math.sin(rlat2) -
      math.sin(rlat1) * math.cos(rlat2) * math.cos(dlon);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _haversine(double lat1, double lng1, double lat2, double lng2) {
  const double r = 6371000.0;
  final double p1 = lat1 * math.pi / 180;
  final double p2 = lat2 * math.pi / 180;
  final double dp = (lat2 - lat1) * math.pi / 180;
  final double dl = (lng2 - lng1) * math.pi / 180;
  final double a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

/// 从最近的 GPS 轨迹估计稳定移动方向。
///
/// [lastReliableHeading]/[lastReliableAgeMs] 由调用方保存，用于短暂停止时
/// 回退到最近一次可靠方向；[now] 可注入以便单元测试。
HeadingEstimate estimateRunHeading({
  required List<TrackPoint> points,
  double? lastReliableHeading,
  int? lastReliableAgeMs,
  DateTime? now,
}) {
  final DateTime t = now ?? DateTime.now();
  final int nowMs = t.millisecondsSinceEpoch;
  final List<TrackPoint> recent = points
      .where((TrackPoint p) =>
          p.accuracy <= 50 &&
          p.latitude.abs() <= 90 &&
          p.longitude.abs() <= 180 &&
          nowMs - p.timestamp.millisecondsSinceEpoch <= 30000)
      .toList(growable: false);
  final List<TrackPoint> tail =
      recent.length > 9 ? recent.sublist(recent.length - 9) : recent;

  final List<TrackPoint> clean = <TrackPoint>[];
  for (final TrackPoint p in tail) {
    if (clean.isEmpty ||
        _haversine(clean.last.latitude, clean.last.longitude,
                p.latitude, p.longitude) >=
            2.0) {
      clean.add(p);
    }
  }

  if (clean.length >= 2) {
    final TrackPoint a = clean.first;
    final TrackPoint b = clean.last;
    final double d = _haversine(a.latitude, a.longitude, b.latitude, b.longitude);
    final double dt =
        (b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0).abs();
    if (d >= 8.0 && dt >= 2.0 && d / math.max(dt, 0.1) >= 0.6) {
      final double h =
          _bearingDeg(a.latitude, a.longitude, b.latitude, b.longitude);
      final double conf = math.min(
              0.9,
              0.45 +
                  0.08 * math.min(clean.length, 5) +
                  (d >= 20 ? 0.2 : 0))
          .toDouble();
      return HeadingEstimate(
        heading: h,
        source: 'recent_points',
        confidence: double.parse(conf.toStringAsFixed(2)),
        ageMs: nowMs - b.timestamp.millisecondsSinceEpoch,
      );
    }
  }

  if (lastReliableHeading != null &&
      lastReliableAgeMs != null &&
      lastReliableAgeMs <= 30000) {
    return HeadingEstimate(
      heading: lastReliableHeading % 360,
      source: 'frozen',
      confidence: 0.4,
      ageMs: lastReliableAgeMs,
    );
  }

  if (tail.isNotEmpty) {
    final TrackPoint p = tail.last;
    if (p.bearing != null && p.speed >= 1.0 && p.accuracy <= 40) {
      return HeadingEstimate(
        heading: p.bearing! % 360,
        source: 'gps_course',
        confidence: 0.55,
        ageMs: nowMs - p.timestamp.millisecondsSinceEpoch,
      );
    }
  }
  return HeadingEstimate.none;
}
