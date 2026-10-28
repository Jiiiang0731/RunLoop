import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/track_point.dart';
import 'package:runloop/services/run_recorder/gps_filter.dart';

TrackPoint _pt(double lat, double lng, double acc, DateTime t) => TrackPoint(
      latitude: lat,
      longitude: lng,
      accuracy: acc,
      speed: 0,
      timestamp: t,
    );

void main() {
  const GpsFilter filter =
      GpsFilter(maxAccuracyMeters: 50, maxJumpMeters: 100, minMovingSpeed: 0.5);
  final DateTime t0 = DateTime(2024, 1, 1, 10, 0, 0);

  test('接受首个精度正常的点', () {
    final GpsFilterDecision d = filter.evaluate(_pt(31, 121, 10, t0), null);
    expect(d.accepted, isTrue);
  });

  test('丢弃精度过差的点', () {
    final GpsFilterDecision d = filter.evaluate(_pt(31, 121, 200, t0), null);
    expect(d.accepted, isFalse);
  });

  test('丢弃跳点', () {
    final TrackPoint prev = _pt(31, 121, 10, t0);
    // 0.01 经度约 950m，远大于 100m 阈值
    final GpsFilterDecision d =
        filter.evaluate(_pt(31, 121.01, 10, t0.add(const Duration(seconds: 5))), prev);
    expect(d.accepted, isFalse);
  });

  test('识别移动状态', () {
    final TrackPoint prev = _pt(31, 121, 10, t0);
    // 0.0002 经度约 19m，2 秒约 9.5 m/s，判定为移动
    final GpsFilterDecision d =
        filter.evaluate(_pt(31, 121.0002, 10, t0.add(const Duration(seconds: 2))), prev);
    expect(d.accepted, isTrue);
    expect(d.isMoving, isTrue);
  });
}
