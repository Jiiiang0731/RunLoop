import 'dart:math' as math;

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/utils/dual_track.dart';
import 'package:runloop/utils/map_icons.dart';

/// 阶段 N：去返程并排双轨（任务书 6.3）纯几何测试。
///
/// 这些测试守住两条铁律：
/// 1. 偏移只影响显示——输入折线点绝不被修改；
/// 2. 两条轨道必须真正分开（间距 ≈ 2×offsetPx 换算的米数），
///    不是把同一条线画两遍。
void main() {
  const double lat0 = 30.45;
  const double lng0 = 114.17;

  /// 东西向折线：向东 [n] 个点，相邻约 [stepM] 米。
  List<LatLng> eastLine(int n, {double stepM = 30}) {
    final double dlng = stepM / (111320.0 * math.cos(lat0 * math.pi / 180));
    return List<LatLng>.generate(
        n, (int i) => LatLng(lat0, lng0 + dlng * i));
  }

  /// 原路折返：向东 n 点再原路返回（共 2n 点）。
  List<LatLng> outAndBack(int n, {double stepM = 30}) {
    final List<LatLng> out = eastLine(n, stepM: stepM);
    return <LatLng>[...out, ...out.reversed.skip(1)];
  }

  group('offsetPolyline（垂线偏移，纯显示）', () {
    test('东行线向右偏移 → 整体南移，且不修改输入', () {
      final List<LatLng> src = eastLine(5, stepM: 40);
      final List<LatLng> before = List<LatLng>.of(src);
      final List<LatLng> shifted = offsetPolyline(src, 1, 12.0);
      expect(shifted.length, src.length);
      for (int i = 0; i < src.length; i++) {
        expect(src[i].latitude, before[i].latitude, reason: '输入必须不变');
        expect(src[i].longitude, before[i].longitude);
        expect(shifted[i].latitude, lessThan(src[i].latitude),
            reason: '东行时右侧 = 南');
        expect(haversineMeters(shifted[i], src[i]), closeTo(12.0, 0.6));
      }
    });

    test('左侧偏移方向相反，且两侧对称', () {
      final List<LatLng> src = eastLine(4, stepM: 20);
      final List<LatLng> right = offsetPolyline(src, 1, 10.0);
      final List<LatLng> left = offsetPolyline(src, -1, 10.0);
      for (int i = 0; i < src.length; i++) {
        expect(haversineMeters(right[i], left[i]), closeTo(20.0, 1.0),
            reason: '两侧轨道间距 ≈ 2×偏移量');
      }
    });
  });

  group('findFoldPasses（原路折返识别）', () {
    test('东西向原路折返 → 识别出一段折返', () {
      final List<FoldPass> folds = findFoldPasses(outAndBack(12));
      expect(folds, isNotEmpty);
      expect(folds.first.spanM, greaterThan(300));
      expect(folds.first.valid, isTrue);
    });

    test('干净方环（无重复路段）→ 不产生折返轨道', () {
      final double d = 200 / 110574.0; // 约 200m
      final List<LatLng> square = <LatLng>[
        LatLng(lat0, lng0),
        LatLng(lat0, lng0 + d),
        LatLng(lat0 + d, lng0 + d),
        LatLng(lat0 + d, lng0),
        LatLng(lat0, lng0),
      ];
      expect(findFoldPasses(square), isEmpty);
    });

    test('直线（无折返）→ 空', () {
      expect(findFoldPasses(eastLine(20)), isEmpty);
    });
  });

  group('buildDisplayTracks（两条并行轨道）', () {
    test('折返段生成去/返两条轨道，间距 = 2×offsetPx 换算米数', () {
      final List<LatLng> pts = outAndBack(12);
      final List<FoldPass> folds = findFoldPasses(pts);
      expect(folds, isNotEmpty);
      const double mpp = 0.9; // 米/像素
      final List<DisplayTrack> tracks =
          buildDisplayTracks(pts, folds, metersPerPx: mpp, offsetPx: 7);
      expect(tracks.length, 2, reason: '一段折返 = 去/返两条轨道');
      expect(tracks[0].isBack, isFalse);
      expect(tracks[1].isBack, isTrue);
      expect(tracks[0].points.length, greaterThanOrEqualTo(2));
      expect(tracks[1].points.length, greaterThanOrEqualTo(2));

      // 两条轨道必须在中心线两侧：分别校验到源折线中点的垂直距离
      final FoldPass f = folds.first;
      final List<LatLng> outSeg = pts.sublist(f.outStart, f.outEnd + 1);
      final List<LatLng> backSeg = pts.sublist(f.backStart, f.backEnd + 1);
      final double dOut =
          haversineMeters(tracks[0].points.first, outSeg.first);
      final double dBack =
          haversineMeters(tracks[1].points.first, backSeg.first);
      expect(dOut, closeTo(7 * mpp, 0.5));
      expect(dBack, closeTo(7 * mpp, 0.5));
      // 轨道确实分居两侧（纬度方向相反）
      expect((tracks[0].points.first.latitude - lat0) *
          (tracks[1].points.first.latitude - lat0), lessThan(0));
    });

    test('偏移只作用于显示：输入点列保持不变', () {
      final List<LatLng> pts = outAndBack(10);
      final List<double> before =
          pts.map((LatLng p) => p.latitude * 1e6 + p.longitude).toList();
      buildDisplayTracks(pts, findFoldPasses(pts), metersPerPx: 1.0);
      final List<double> after =
          pts.map((LatLng p) => p.latitude * 1e6 + p.longitude).toList();
      expect(after, before);
    });
  });
}
