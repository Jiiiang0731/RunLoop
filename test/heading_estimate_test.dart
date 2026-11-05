import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/track_point.dart';
import 'package:runloop/utils/heading_estimate.dart';

TrackPoint _p(double lat, double lng, DateTime t,
    {double acc = 5, double speed = 3, double? bearing}) {
  return TrackPoint(
    latitude: lat,
    longitude: lng,
    accuracy: acc,
    speed: speed,
    timestamp: t,
    bearing: bearing,
  );
}

void main() {
  final DateTime now = DateTime(2026, 1, 1, 8, 0, 0);

  group('阶段 Q 方向估计', () {
    test('连续向东移动 → 约 90°', () {
      final List<TrackPoint> pts = <TrackPoint>[
        _p(39.9, 116.0000, now.subtract(const Duration(seconds: 8))),
        _p(39.9, 116.00005, now.subtract(const Duration(seconds: 4))),
        _p(39.9, 116.00010, now),
      ];
      final HeadingEstimate e = estimateRunHeading(points: pts, now: now);
      expect(e.heading, closeTo(90, 5));
      expect(e.source, 'recent_points');
      expect(e.reliable, isTrue);
      expect(e.ageMs, lessThan(1000));
    });

    test('精度差的点被过滤 → 使用最近可靠方向 frozen', () {
      final List<TrackPoint> pts = <TrackPoint>[
        _p(39.9, 116.0000, now.subtract(const Duration(seconds: 3)), acc: 90),
        _p(39.9, 116.0002, now, acc: 80),
      ];
      final HeadingEstimate e = estimateRunHeading(
        points: pts,
        lastReliableHeading: 45,
        lastReliableAgeMs: 5000,
        now: now,
      );
      expect(e.source, 'frozen');
      expect(e.heading, 45);
      expect(e.confidence, 0.4);
    });

    test('静止漂移不足以产生方向 → frozen', () {
      final List<TrackPoint> pts = <TrackPoint>[
        _p(39.9, 116.0, now.subtract(const Duration(seconds: 5))),
        _p(39.9, 116.00001, now),
      ];
      final HeadingEstimate e = estimateRunHeading(
        points: pts,
        lastReliableHeading: 120,
        lastReliableAgeMs: 2000,
        now: now,
      );
      expect(e.source, 'frozen');
      expect(e.heading, 120);
    });

    test('单点原生 bearing 作为低置信度兜底', () {
      final List<TrackPoint> pts = <TrackPoint>[
        _p(39.9, 116.0, now, speed: 2.0, bearing: 180),
      ];
      final HeadingEstimate e = estimateRunHeading(points: pts, now: now);
      expect(e.source, 'gps_course');
      expect(e.heading, 180);
      expect(e.confidence, closeTo(0.55, 1e-9));
      expect(e.reliable, isTrue);
    });

    test('无数据 → none，绝不编造方向', () {
      final HeadingEstimate e =
          estimateRunHeading(points: const <TrackPoint>[], now: now);
      expect(e.heading, isNull);
      expect(e.source, 'none');
      expect(e.reliable, isFalse);
    });

    test('超过 30 秒的旧点被忽略', () {
      final List<TrackPoint> pts = <TrackPoint>[
        _p(39.9, 116.0000, now.subtract(const Duration(seconds: 40))),
        _p(39.9, 116.0002, now.subtract(const Duration(seconds: 35))),
      ];
      final HeadingEstimate e = estimateRunHeading(points: pts, now: now);
      expect(e.source, 'none');
    });
  });
}
