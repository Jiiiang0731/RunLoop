import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/planned_route.dart';
import 'package:runloop/utils/turn_annotations.dart';

/// 去/返转弯标注的纯几何单元测试（阶段 K 规范③④：标注只读 canonical，
/// 侧偏为像素级换算；这些测试不触碰地图插件，仅验证数学与构建逻辑）。
void main() {
  /// 构造一条「东行 500m 掉头原路返回」的 canonical 折线（21 点）。
  List<List<double>> outAndBackPolyline() {
    final List<List<double>> pts = <List<double>>[];
    for (int k = 0; k <= 10; k++) {
      pts.add(<double>[k * 0.0005, 0.0]); // 去程向东
    }
    for (int k = 9; k >= 0; k--) {
      pts.add(<double>[k * 0.0005, 0.0]); // 返程向西
    }
    return pts;
  }

  PlannedRoute buildRoute({List<OverlapGroup> overlaps = const <OverlapGroup>[]}) {
    final List<List<double>> poly = outAndBackPolyline();
    return PlannedRoute(
      seed: 1,
      distanceM: 1000,
      errorM: 0,
      withinTolerance: true,
      closureM: 0,
      closureOk: true,
      score: 50,
      nPoints: poly.length,
      polyline: poly,
      scoreComponents: const <ScoreItem>[],
      steps: const <RouteStep>[],
      overlaps: overlaps,
    );
  }

  group('metersPerPixel', () {
    test('zoom 越大每像素米数越小', () {
      final double a = metersPerPixel(12, 30.5);
      final double b = metersPerPixel(16, 30.5);
      expect(a, greaterThan(b));
      expect(a / b, closeTo(16, 0.01)); // 2^4
    });

    test('量级正确（zoom14 武汉纬度约 8m/px）', () {
      expect(metersPerPixel(14, 30.5), closeTo(8.2, 0.3));
    });
  });

  group('offsetPerpendicular', () {
    test('北行时右侧=东、左侧=西，距离精确', () {
      const LatLng p = LatLng(30.5, 114.1);
      final LatLng right = offsetPerpendicular(p, 0, 16, 1);
      final LatLng left = offsetPerpendicular(p, 0, 16, -1);
      expect(right.latitude, closeTo(p.latitude, 1e-9));
      expect(right.longitude, greaterThan(p.longitude));
      expect(left.longitude, lessThan(p.longitude));
      // 16m 换算经度差（111320×cos30.5 ≈ 95950 m/°）
      expect((right.longitude - p.longitude) * 95950, closeTo(16, 0.5));
      expect((p.longitude - left.longitude) * 95950, closeTo(16, 0.5));
    });

    test('东行时右侧=南（北半球），旋转不变性由地理垂线保证', () {
      const LatLng p = LatLng(30.5, 114.1);
      final LatLng right = offsetPerpendicular(p, 90, 10, 1);
      expect(right.latitude, lessThan(p.latitude));
      expect(right.longitude, closeTo(p.longitude, 1e-9));
    });

    test('两侧对称：side 取反结果关于原点镜像', () {
      const LatLng p = LatLng(30.5, 114.1);
      final LatLng a = offsetPerpendicular(p, 37, 12, 1);
      final LatLng b = offsetPerpendicular(p, 37, 12, -1);
      expect(a.latitude + b.latitude, closeTo(2 * p.latitude, 1e-9));
      expect(a.longitude + b.longitude, closeTo(2 * p.longitude, 1e-9));
    });
  });

  group('findUTurnVertices', () {
    test('原路折返在尖点处检出', () {
      final List<LatLng> pts = outAndBackPolyline()
          .map((List<double> e) => LatLng(e[1], e[0]))
          .toList();
      final List<int> apexes = findUTurnVertices(pts);
      expect(apexes, contains(10));
    });

    test('直线无折返', () {
      final List<LatLng> pts = <LatLng>[
        for (int k = 0; k < 12; k++) LatLng(30.0 + k * 0.001, 114.0),
      ];
      expect(findUTurnVertices(pts), isEmpty);
    });
  });

  group('buildTurnAnnotations', () {
    test('U 形折返 → 成对去/返标注，两侧相反', () {
      final List<TurnAnnotation> anns = buildTurnAnnotations(buildRoute());
      expect(anns.length, 2);
      final TurnAnnotation out =
          anns.firstWhere((TurnAnnotation a) => a.kind == TurnKind.out);
      final TurnAnnotation back =
          anns.firstWhere((TurnAnnotation a) => a.kind == TurnKind.back);
      expect(out.side, -1);
      expect(back.side, 1);
      expect(out.label, '去程');
      expect(back.label, '返程');
      // 去在尖点前、返在尖点后（累计里程递增排序）
      expect(out.cumM, lessThan(back.cumM));
    });

    test('服务端 overlaps pass 对 → 中点标注 + 累计里程来自服务端', () {
      final List<OverlapGroup> overlaps = <OverlapGroup>[
        OverlapGroup(
          refBearing: 90,
          direction: 'reverse',
          ranges: const <OverlapRange>[],
          passes: const <OverlapPass>[
            OverlapPass(pass: 1, start: 2, end: 8, cumStartM: 100, cumEndM: 400),
            OverlapPass(pass: 2, start: 13, end: 19, cumStartM: 600, cumEndM: 900),
          ],
        ),
      ];
      final List<TurnAnnotation> anns =
          buildTurnAnnotations(buildRoute(overlaps: overlaps));
      final Iterable<TurnAnnotation> g0 = anns.where(
          (TurnAnnotation a) => a.id.startsWith('ta-g0'));
      expect(g0.length, 2);
      final TurnAnnotation out =
          g0.firstWhere((TurnAnnotation a) => a.kind == TurnKind.out);
      final TurnAnnotation back =
          g0.firstWhere((TurnAnnotation a) => a.kind == TurnKind.back);
      expect(out.side, -1);
      expect(back.side, 1);
      // 中点：pass1 mid=(2+8)/2=5 → x=0.0025；pass2 mid=(13+19)/2=16 → x=0.002
      expect(out.at.longitude, closeTo(0.0025, 1e-9));
      expect(back.at.longitude, closeTo(0.002, 1e-9));
      // 累计里程取服务端区间中值
      expect(out.cumM, closeTo(250, 1e-9));
      expect(back.cumM, closeTo(750, 1e-9));
    });

    test('canonical 折线不被修改（纯视觉铁律）', () {
      final PlannedRoute r = buildRoute();
      final List<List<double>> before =
          r.polyline.map((List<double> p) => List<double>.of(p)).toList();
      buildTurnAnnotations(r);
      expect(r.polyline, before);
    });

    test('v1 数据兼容：仅 ranges 无 passes → 由 ranges 派生', () {
      final OverlapGroup g = OverlapGroup.fromJson(<String, dynamic>{
        'ref_bearing': 90.0,
        'ranges': <Map<String, dynamic>>[
          <String, dynamic>{'start': 2, 'end': 8, 'offset': -1.0},
          <String, dynamic>{'start': 13, 'end': 19, 'offset': 1.0},
        ],
      });
      expect(g.passes.length, 2);
      expect(g.passes[0].start, 2);
      expect(g.passes[1].end, 19);
      expect(g.direction, 'reverse');
    });
  });

  group('planArrowPlacements（阶段 M-F 6.2）', () {
    List<LatLng> pts() => outAndBackPolyline()
        .map((List<double> p) => LatLng(p[1], p[0]))
        .toList();

    test('直行段稀疏均匀布点，方位角取真实前进方向', () {
      final List<ArrowPlacement> as1 = planArrowPlacements(
        pts(),
        overlaps: const <OverlapGroup>[],
        annotations: const <TurnAnnotation>[],
        spacingMeters: 300,
      );
      expect(as1.length, 3);
      // 去程箭头指向东（≈90°），返程箭头指向西（≈270°）
      expect(as1[0].bearing, closeTo(90, 1));
      expect(as1[1].bearing, closeTo(270, 1));
      // 里程递增、间距 ≈ spacing
      expect(as1[1].cumM, greaterThan(as1[0].cumM));
      expect(as1[1].cumM - as1[0].cumM, closeTo(300, 60));
    });

    test('overlaps pass2 区间内的箭头判定为返程（形状+颜色双编码）', () {
      final List<OverlapGroup> overlaps = <OverlapGroup>[
        OverlapGroup(
          refBearing: 90,
          direction: 'reverse',
          ranges: const <OverlapRange>[],
          passes: const <OverlapPass>[
            OverlapPass(pass: 1, start: 2, end: 8, cumStartM: 100, cumEndM: 400),
            OverlapPass(
                pass: 2, start: 13, end: 19, cumStartM: 560, cumEndM: 1113),
          ],
        ),
      ];
      final List<ArrowPlacement> as1 = planArrowPlacements(
        pts(),
        overlaps: overlaps,
        annotations: const <TurnAnnotation>[],
        spacingMeters: 300,
      );
      expect(as1[0].back, isFalse, reason: '去程段箭头 = 实心');
      expect(as1[1].back, isTrue, reason: 'pass2 段箭头 = 空心');
      expect(as1[2].back, isTrue);
    });

    test('转弯标注避让带内不布箭头（不堆叠，各司其职）', () {
      final List<TurnAnnotation> anns = <TurnAnnotation>[
        TurnAnnotation(
          id: 'ta-x-out',
          at: pts()[11],
          bearing: 270,
          side: -1,
          kind: TurnKind.out,
          cumM: 612,
          priorityM: 100,
        ),
      ];
      final List<ArrowPlacement> as1 = planArrowPlacements(
        pts(),
        overlaps: const <OverlapGroup>[],
        annotations: anns,
        spacingMeters: 300,
        avoidM: 150,
      );
      expect(as1.length, 2, reason: '612m 处的箭头被标注避让带跳过');
      for (final ArrowPlacement a in as1) {
        expect((a.cumM - 612).abs(), greaterThanOrEqualTo(150));
      }
    });

    test('maxCount 上限与非法参数兜底', () {
      final List<ArrowPlacement> many = planArrowPlacements(
        pts(),
        overlaps: const <OverlapGroup>[],
        annotations: const <TurnAnnotation>[],
        spacingMeters: 60,
        maxCount: 4,
      );
      expect(many.length, lessThanOrEqualTo(4));
      expect(
        planArrowPlacements(<LatLng>[pts()[0], pts()[1]],
            overlaps: const <OverlapGroup>[],
            annotations: const <TurnAnnotation>[]),
        isEmpty,
      );
    });

    test('布点绝不修改真实坐标（纯视觉铁律）', () {
      final List<LatLng> p = pts();
      final List<double> before =
          p.map((LatLng e) => e.longitude * 1e6 + e.latitude).toList();
      planArrowPlacements(p,
          overlaps: const <OverlapGroup>[],
          annotations: const <TurnAnnotation>[],
          spacingMeters: 300);
      final List<double> after =
          p.map((LatLng e) => e.longitude * 1e6 + e.latitude).toList();
      expect(after, before);
    });
  });
}
