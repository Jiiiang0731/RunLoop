import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/utils/route_path.dart';

void main() {
  // 沿经度方向的直线（纬度 30°，每 0.001° 约 96m）
  final List<LatLng> pts = <LatLng>[
    const LatLng(30.0, 114.000),
    const LatLng(30.0, 114.001),
    const LatLng(30.0, 114.002),
    const LatLng(30.0, 114.003),
  ];
  final RoutePath path = RoutePath.fromPoints(pts);

  test('总距离大于 0 且约为三段之和', () {
    expect(path.total, greaterThan(0));
    expect(path.total, closeTo(288, 15)); // 3 × ~96m
  });

  test('at(0) 在起点、at(total) 在终点', () {
    expect(path.at(0).point.latitude, closeTo(30.0, 1e-9));
    expect(path.at(0).point.longitude, closeTo(114.000, 1e-6));
    expect(path.at(path.total).point.longitude, closeTo(114.003, 1e-6));
  });

  test('at(中点) 插值落在折线上', () {
    final RoutePosition pos = path.at(path.total / 2);
    expect(pos.point.longitude, greaterThan(114.000));
    expect(pos.point.longitude, lessThan(114.003));
    // 方向应接近正东（90°）或正西（270°）
    expect((pos.bearing - 90).abs() < 1 || (pos.bearing - 270).abs() < 1, isTrue);
  });

  test('upTo(0) 只返回起点', () {
    expect(path.upTo(0).length, 1);
  });

  test('upTo(total) 返回全部点', () {
    expect(path.upTo(path.total).length, pts.length);
  });

  test('upTo(中途) 返回前缀 + 插值点', () {
    final List<LatLng> mid = path.upTo(path.total / 2);
    expect(mid.length, greaterThanOrEqualTo(2));
    expect(mid.length, lessThanOrEqualTo(pts.length));
  });

  test('at(负值) 与 at(超长) 被正确截断', () {
    expect(path.at(-50).point.longitude, closeTo(114.000, 1e-6));
    expect(path.at(path.total + 500).point.longitude, closeTo(114.003, 1e-6));
  });
}
