import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/utils/route_path.dart';

/// 模块 E：已跑/剩余折线拆分（upTo / fromDistance 互补且首尾衔接）。
void main() {
  final List<LatLng> pts = <LatLng>[
    const LatLng(30, 120),
    const LatLng(30, 120.01),
    const LatLng(30, 120.02),
  ];
  final RoutePath path = RoutePath.fromPoints(pts);

  test('边界值：upTo(0) 只含起点，fromDistance(0) 含全部点', () {
    expect(path.upTo(0).length, 1);
    expect(path.fromDistance(0).length, 3);
    expect(path.fromDistance(0).first.latitude, 30);
    expect(path.fromDistance(0).first.longitude, 120);
  });

  test('边界值：upTo(total) 含全部点，fromDistance(total) 只含终点', () {
    expect(path.upTo(path.total).length, 3);
    expect(path.fromDistance(path.total).length, 1);
    expect(path.fromDistance(path.total).first.longitude, closeTo(120.02, 1e-9));
  });

  test('中点拆分：两段在插值点无缝衔接、无重叠丢失', () {
    final double d = path.total / 2; // 恰好是第二个顶点
    final List<LatLng> u = path.upTo(d);
    final List<LatLng> f = path.fromDistance(d);
    expect(u.length, 2);
    expect(f.length, 2);
    expect(u.last.longitude, closeTo(f.first.longitude, 1e-9));
    expect(u.last.latitude, closeTo(f.first.latitude, 1e-9));
  });

  test('段内任意距离拆分：插值端点一致，两段覆盖全程', () {
    final double d = path.total * 0.3; // 第一段内部
    final List<LatLng> u = path.upTo(d);
    final List<LatLng> f = path.fromDistance(d);
    expect(u.length, 2); // 起点 + 插值点
    expect(f.length, 3); // 插值点 + 后两个顶点
    expect(u.last.longitude, closeTo(f.first.longitude, 1e-9));
    expect(u.last.latitude, closeTo(f.first.latitude, 1e-9));
    // 插值点位置正确（沿纬线 30% 处）
    expect(u.last.longitude, closeTo(120 + 0.02 * 0.3, 1e-6));
  });

  test('越界距离被 clamp，不抛异常', () {
    expect(path.upTo(-50).length, 1);
    expect(path.fromDistance(-50).length, 3);
    expect(path.upTo(path.total + 500).length, 3);
    expect(path.fromDistance(path.total + 500).length, 1);
  });

  test('空路线/单点路线安全', () {
    expect(RoutePath.fromPoints(<LatLng>[]).fromDistance(10), isEmpty);
    expect(RoutePath.fromPoints(<LatLng>[const LatLng(1, 2)]).fromDistance(0).length, 1);
  });
}
