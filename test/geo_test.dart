import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/utils/geo.dart';

void main() {
  test('haversine 1 degree latitude ≈ 111km', () {
    final double d = haversineMeters(31.0, 121.0, 32.0, 121.0);
    expect(d, closeTo(111195, 100));
  });

  test('haversine small longitude distance', () {
    // 纬度 31° 处，0.001 经度约 95m。
    final double d = haversineMeters(31.0, 121.0, 31.0, 121.001);
    expect(d, closeTo(95.4, 10));
  });

  test('formatPace', () {
    expect(formatPace(300), "5'00\"");
    expect(formatPace(0), '--\'--"');
    expect(formatPace(null), '--\'--"');
  });

  test('formatDuration', () {
    expect(formatDuration(65), '1:05');
    expect(formatDuration(3725), '1:02:05');
  });

  test('formatKm', () {
    expect(formatKm(15000), '15.00');
    expect(formatKm(500), '0.50');
  });
}
