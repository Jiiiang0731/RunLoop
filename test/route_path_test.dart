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

  test('模拟生长动画：进度增加时已绘制折线单调增长', () {
    int prevLen = 0;
    for (int i = 0; i <= 20; i++) {
      final List<LatLng> drawn = path.upTo(path.total * i / 20);
      expect(drawn.length, greaterThanOrEqualTo(prevLen));
      prevLen = drawn.length;
    }
    expect(prevLen, pts.length);
  });

  test('动画结束时已绘制折线等于完整路线', () {
    expect(path.upTo(path.total), equals(pts));
  });

  group('project 投影（阶段 J：跑步页进度/偏航）', () {
    test('线上的点：垂距≈0，沿线里程正确', () {
      // 114.0015 在第 2 段中点：沿线 ≈ 1.5 段 ≈ 144m
      final RouteProjection p = path.project(const LatLng(30.0, 114.0015));
      expect(p.offsetM, lessThan(1.0));
      expect(p.alongM, closeTo(path.total / 2, 15));
    });

    test('线外的点：垂距 = 到线距离，投影点落回线上', () {
      // 向北偏 0.001° ≈ 111m
      final RouteProjection p = path.project(const LatLng(30.001, 114.001));
      expect(p.offsetM, closeTo(111, 6));
      expect(p.point.latitude, closeTo(30.0, 1e-6));
      expect(p.alongM, closeTo(96, 10));
    });

    test('超出端点被截断到起点/终点', () {
      expect(path.project(const LatLng(30.0, 113.99)).alongM, closeTo(0, 1e-6));
      expect(path.project(const LatLng(30.0, 114.01)).alongM, closeTo(path.total, 1e-6));
    });

    test('at(d) 的点投影回来 along≈d、offset≈0（往返一致）', () {
      for (final double frac in <double>[0.1, 0.37, 0.62, 0.9]) {
        final double d = path.total * frac;
        final RouteProjection p = path.project(path.at(d).point);
        expect(p.alongM, closeTo(d, 2.0));
        expect(p.offsetM, lessThan(1.0));
      }
    });
  });

  group('projectNear 窗口化投影（去/返程重叠腿不串线）', () {
    // 出返程完全重叠：A → B → A
    final RoutePath outBack = RoutePath.fromPoints(<LatLng>[
      const LatLng(30.0, 114.000),
      const LatLng(30.0, 114.002),
      const LatLng(30.0, 114.000),
    ]);
    const LatLng mid = LatLng(30.0, 114.001);

    test('全局投影取最先命中的去程腿', () {
      final RouteProjection g = outBack.project(mid);
      expect(g.offsetM, lessThan(1.0));
      expect(g.alongM, closeTo(outBack.total / 4, 10)); // 去程 ≈ 96m
    });

    test('提示在返程时，窗口投影锁定返程腿', () {
      final RouteProjection n = outBack.projectNear(
          mid, outBack.total * 0.75, 100); // 提示 ≈ 289m（返程中段）
      expect(n.offsetM, lessThan(1.0));
      expect(n.alongM, closeTo(outBack.total * 0.75, 15));
      expect(n.alongM, greaterThan(outBack.total / 2)); // 不是去程
    });

    test('提示为空时退化为全局投影', () {
      final RouteProjection n = outBack.projectNear(mid, null, 100);
      expect(n.alongM, closeTo(outBack.total / 4, 10));
    });
  });
}
