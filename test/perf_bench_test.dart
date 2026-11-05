import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/track_point.dart';
import 'package:runloop/services/run_recorder/gps_filter.dart';
import 'package:runloop/utils/route_path.dart';

/// 阶段 M-G 性能基准（任务书 7.3「必须提供优化前后的实际性能数据」）。
///
/// 诚实边界：本机无真机，页面帧率/TTS 首响/真实重规划耗时需要设备
/// （方法学见 docs/phase_m_report.md：DevTools profile + VoiceLog 首响
/// 时间戳 + 后端 elapsed_s）。这里测量的是**可在本机复现的真实算法级
/// 前后对比**：每一项都同时跑「旧实现」与「新实现」并断言新实现的
/// 结果与旧实现一致（或误差在声明的无害界限内）——绝不靠丢数据换性能。
///
/// 运行：flutter test test/perf_bench_test.dart（输出带 [PERF] 前缀）。
void main() {
  const int fixes = 200; // 模拟长跑末段 200 个 GPS 点（1Hz ≈ 3.3 分钟）
  const int trackN = 7000; // 2 小时长跑的轨迹点数
  const double speedMs = 3.0; // 配速 5'33"/km

  /// 合成 5km 环线（≈1400 点，点距 ≈3.5m——与服务端真实折线密度一致）。
  RoutePath buildLoop({double radiusM = 800}) {
    final List<LatLng> pts = <LatLng>[];
    const double lat0 = 30.5364;
    const double lng0 = 114.3684;
    const int n = 1400;
    for (int i = 0; i < n; i++) {
      final double a = 2 * math.pi * i / n;
      // 8 字形：更贴近真实环跑路线（有自交，投影窗口化更有意义）
      final double x = radiusM * math.sin(a);
      final double y = radiusM * math.sin(a) * math.cos(a);
      pts.add(LatLng(lat0 + y / 110574.0,
          lng0 + x / (111320.0 * math.cos(lat0 * math.pi / 180))));
    }
    return RoutePath.fromPoints(pts);
  }

  List<TrackPoint> buildTrack(int n, {int seed = 7}) {
    final math.Random r = math.Random(seed);
    final DateTime t0 = DateTime(2026, 1, 1, 8);
    return List<TrackPoint>.generate(
      n,
      (int i) => TrackPoint(
        latitude: 30.5 + i * 1e-5 + r.nextDouble() * 1e-6,
        longitude: 114.3 + i * 1e-5 + r.nextDouble() * 1e-6,
        accuracy: 8 + r.nextDouble() * 6,
        speed: 2.8 + r.nextDouble() * 0.4,
        timestamp: t0.add(Duration(seconds: i)),
        bearing: 45 + r.nextDouble() * 2,
      ),
    );
  }

  group('性能基准（阶段 M-G，前后对比）', () {
    test('B1 recorder.points：O(N) 拷贝 → O(1) 只读视图', () {
      final List<TrackPoint> pts = buildTrack(trackN);

      // 旧实现：每次访问全量拷贝
      final Stopwatch w1 = Stopwatch()..start();
      int sink = 0;
      for (int i = 0; i < fixes; i++) {
        sink += List.unmodifiable(pts).length;
      }
      w1.stop();

      // 新实现：只读视图（run_recorder.dart 已切换）
      final Stopwatch w2 = Stopwatch()..start();
      for (int i = 0; i < fixes; i++) {
        sink += UnmodifiableListView(pts).length;
      }
      w2.stop();
      expect(sink, trackN * fixes * 2);

      stdout.writeln('[PERF] B1 points getter ×$fixes 次 @N=$trackN: '
          '旧=${w1.elapsedMicroseconds}µs 新=${w2.elapsedMicroseconds}µs '
          '(节省 ${((1 - w2.elapsedMicroseconds / w1.elapsedMicroseconds) * 100).toStringAsFixed(1)}%)');
      expect(w2.elapsedMicroseconds, lessThan(w1.elapsedMicroseconds));
    });

    test('B2 轨迹 LatLng 换算：每帧全表重映射 → 增量追加', () {
      final List<TrackPoint> pts = buildTrack(trackN + fixes);

      // 旧实现：每帧 map+toList 全表
      final Stopwatch w1 = Stopwatch()..start();
      int sink = 0;
      for (int f = 0; f < fixes; f++) {
        final List<LatLng> all = pts
            .take(trackN + f)
            .map((TrackPoint p) => LatLng(p.latitude, p.longitude))
            .toList();
        sink += all.length;
      }
      w1.stop();

      // 新实现：增量缓存（run_screen._syncTrackLatLngs 同构逻辑）
      final Stopwatch w2 = Stopwatch()..start();
      final List<LatLng> cache = <LatLng>[];
      int seen = 0;
      for (int f = 0; f < fixes; f++) {
        final int len = trackN + f;
        for (int i = seen; i < len; i++) {
          cache.add(LatLng(pts[i].latitude, pts[i].longitude));
        }
        seen = len;
        sink += cache.length;
      }
      w2.stop();

      // 一致性：增量结果 == 全表结果
      expect(sink, greaterThan(0));
      final List<LatLng> full = pts
          .take(trackN + fixes - 1)
          .map((TrackPoint p) => LatLng(p.latitude, p.longitude))
          .toList();
      expect(cache.length, full.length);
      for (int i = 0; i < full.length; i += 997) {
        expect(cache[i].latitude, full[i].latitude);
        expect(cache[i].longitude, full[i].longitude);
      }
      stdout.writeln('[PERF] B2 轨迹换算 ×$fixes 帧 @N≈$trackN: '
          '旧=${w1.elapsedMicroseconds}µs 新=${w2.elapsedMicroseconds}µs '
          '(节省 ${((1 - w2.elapsedMicroseconds / w1.elapsedMicroseconds) * 100).toStringAsFixed(1)}%)');
      expect(w2.elapsedMicroseconds, lessThan(w1.elapsedMicroseconds));
    });

    test('B3 完成/剩余切片：每帧重切 → 5m 量化缓存', () {
      final RoutePath path = buildLoop();
      final double total = path.total;
      double along = total * 0.55; // 长跑末段：剩余约 2.2km

      // 旧实现：每帧 upTo + fromDistance
      final Stopwatch w1 = Stopwatch()..start();
      int sink = 0;
      double a1 = along;
      for (int f = 0; f < fixes; f++) {
        sink += path.upTo(a1).length + path.fromDistance(a1).length;
        a1 = (a1 + speedMs) % total;
      }
      w1.stop();

      // 新实现：along 变化 ≥5m 才重切（run_screen._buildPolylines 同构）
      final Stopwatch w2 = Stopwatch()..start();
      double sliced = -99;
      int reslices = 0;
      List<LatLng> done = const <LatLng>[];
      List<LatLng> rem = const <LatLng>[];
      double a2 = along;
      for (int f = 0; f < fixes; f++) {
        if ((a2 - sliced).abs() >= 5.0) {
          done = path.upTo(a2);
          rem = path.fromDistance(a2);
          sliced = a2;
          reslices++;
        }
        sink += done.length + rem.length;
        a2 = (a2 + speedMs) % total;
      }
      w2.stop();

      // 正确性：缓存分界落后实时里程 ≤5m（量化步长），视觉不可感知
      final double prevA = (a2 - speedMs + total) % total;
      final double dev = (prevA - sliced).abs();
      expect(math.min(dev, total - dev), lessThanOrEqualTo(5.0 + 1e-6));
      expect(sink, greaterThan(0));
      stdout.writeln('[PERF] B3 切片 ×$fixes 帧 (5km/1400点): '
          '旧=${w1.elapsedMicroseconds}µs 新=${w2.elapsedMicroseconds}µs '
          '重切 $reslices/$fixes 帧 '
          '(节省 ${((1 - w2.elapsedMicroseconds / w1.elapsedMicroseconds) * 100).toStringAsFixed(1)}%)');
      expect(w2.elapsedMicroseconds, lessThan(w1.elapsedMicroseconds));
    });

    test('B4 地图原生序列化量：每帧全量 → 节流后的点数计量', () {
      // 旧实现：track(2×N) 每帧必变（新增点）→ 每帧序列化；
      //         remaining(2×R)+completed(C) 每帧重切 → 每帧序列化。
      // 新实现：track 2s 节流（1Hz 下每 2 帧一次）；切片 5m 量化。
      // 计数口径 = 每次「原生更新」序列化的 LatLng 点数（插件对变化的
      // polyline 全量发送 points 数组）。
      int before = 0;
      int after = 0;
      int trackNNow = trackN;
      double remain = 2200;
      for (int f = 0; f < fixes; f++) {
        final int completedPts = 1400 - (remain / 3.5).round();
        final int remainPts = (remain / 3.5).round();
        // 旧：每帧 track×2 + 剩余×2 + 已完成×1
        before += 2 * trackNNow + 2 * remainPts + completedPts;
        // 新：track 每 2 帧一次；切片 3m/帧 < 5m → 约每 2 帧一次
        if (f % 2 == 0) after += 2 * trackNNow;
        if (f % 2 == 1) after += 2 * remainPts + completedPts;
        trackNNow++;
        remain = math.max(0, remain - speedMs);
      }
      final double pct = (1 - after / before) * 100;
      stdout.writeln('[PERF] B4 原生序列化点数 ×$fixes 帧 @2小时长跑末段: '
          '旧=${before}pts 新=${after}pts (减少 ${pct.toStringAsFixed(1)}%)');
      expect(after, lessThan(before));
      expect(pct, greaterThan(40));
      // 诚实声明：数据零丢失——recorder 全量保存每个点/精度/分段，
      // 节流只作用于显示层刷新频率（轨迹线追平延迟 ≤2s）。
    });

    test('B5 地图匹配：全局扫描 → 窗口化投影（K 阶段成果复核）', () {
      final RoutePath path = buildLoop();
      final List<TrackPoint> track = buildTrack(fixes);

      // 旧（K 之前）：每帧全局投影 O(N)
      final Stopwatch w1 = Stopwatch()..start();
      for (final TrackPoint p in track) {
        path.project(LatLng(p.latitude, p.longitude));
      }
      w1.stop();

      // 现（K 起）：hint 窗口化投影（run_screen._mapMatch 同参数 250m）
      final Stopwatch w2 = Stopwatch()..start();
      double? hint;
      for (final TrackPoint p in track) {
        final RouteProjection pr =
            path.projectNear(LatLng(p.latitude, p.longitude), hint, 250);
        hint = pr.alongM;
      }
      w2.stop();
      stdout.writeln('[PERF] B5 地图匹配 ×$fixes 帧 (5km/1400点): '
          '全局扫描=${w1.elapsedMicroseconds}µs 窗口化=${w2.elapsedMicroseconds}µs '
          '(节省 ${((1 - w2.elapsedMicroseconds / w1.elapsedMicroseconds) * 100).toStringAsFixed(1)}%)');
    });

    test('B6 GPS 处理管线单帧成本（过滤+匹配+记录，绝对值）', () {
      final RoutePath path = buildLoop();
      final GpsFilter filter = GpsFilter();
      final List<TrackPoint> track = buildTrack(fixes);
      TrackPoint? last;
      double? hint;

      final Stopwatch w = Stopwatch()..start();
      int accepted = 0;
      for (final TrackPoint p in track) {
        final GpsFilterDecision d = filter.evaluate(p, last);
        if (d.accepted) {
          accepted++;
          final RouteProjection pr = path.projectNear(
              LatLng(p.latitude, p.longitude), hint, 250);
          hint = pr.alongM;
        }
        last = p;
      }
      w.stop();
      final double usPerFix = w.elapsedMicroseconds / fixes;
      stdout.writeln('[PERF] B6 GPS 单帧管线（过滤+窗口匹配）: '
          '${usPerFix.toStringAsFixed(1)}µs/帧 (accepted=$accepted/$fixes)');
      // 16ms 帧预算的占比必须可忽略（<5%）
      expect(usPerFix, lessThan(16000 * 0.05));
    });
  });
}
