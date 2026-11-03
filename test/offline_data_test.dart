import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/planned_route.dart';
import 'package:runloop/services/device_id.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 数据连续性（规范④）与离线完整性（规范⑦）的纯 Dart 测试：
/// 入库 → 恢复 的 JSON 往返必须逐字段无损；设备 ID 契约（随机、持久、
/// 无硬件信息）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlannedRoute 离线 JSON 往返', () {
    PlannedRoute buildFull() => const PlannedRoute(
          seed: 7,
          distanceM: 15012.3,
          errorM: 12.3,
          withinTolerance: true,
          closureM: 0.56,
          closureOk: true,
          score: 69.3,
          nPoints: 4,
          polyline: <List<double>>[
            <double>[114.087279, 30.536395],
            <double>[114.090100, 30.537200],
            <double>[114.091300, 30.534100],
            <double>[114.087279, 30.536395],
          ],
          scoreComponents: <ScoreItem>[
            ScoreItem(
                name: '距离达标', score: 100, weight: 0.4, available: true, detail: 'err 12.3m'),
          ],
          steps: <RouteStep>[
            RouteStep(
              instruction: '沿起点向东',
              road: '测试路',
              distanceM: 300,
              cumulativeM: 300,
              action: '直行',
              orientation: '东',
              polyline: <List<double>>[
                <double>[114.087279, 30.536395],
                <double>[114.090100, 30.537200],
              ],
            ),
          ],
          overlaps: <OverlapGroup>[
            OverlapGroup(
              refBearing: 91.5,
              direction: 'reverse',
              ranges: <OverlapRange>[
                OverlapRange(start: 1, end: 2, offset: -1.0),
                OverlapRange(start: 2, end: 3, offset: 1.0),
              ],
              passes: <OverlapPass>[
                OverlapPass(pass: 1, start: 1, end: 2, cumStartM: 300, cumEndM: 620),
                OverlapPass(pass: 2, start: 2, end: 3, cumStartM: 900, cumEndM: 1220),
              ],
            ),
          ],
          metrics: <String, dynamic>{'turns': 17, 'turn_density': 1.14},
          recommended: true,
        );

    test('往返后所有离线关键字段无损（polyline/steps/overlaps/metrics）', () {
      final PlannedRoute src = buildFull();
      // 模拟入库（jsonEncode payload）→ 恢复（decode + fromJson）
      final PlannedRoute restored = PlannedRoute.fromJson(
        jsonDecode(jsonEncode(src.toJson())) as Map<String, dynamic>,
      );

      expect(restored.seed, src.seed);
      expect(restored.distanceM, src.distanceM);
      expect(restored.errorM, src.errorM);
      expect(restored.withinTolerance, src.withinTolerance);
      expect(restored.closureM, src.closureM);
      expect(restored.closureOk, src.closureOk);
      expect(restored.score, src.score);
      expect(restored.recommended, src.recommended);
      // canonical 折线逐点相等（离线恢复不得有任何几何漂移）
      expect(restored.polyline, src.polyline);
      // steps（导航文本离线可用）
      expect(restored.steps.length, 1);
      expect(restored.steps.first.instruction, '沿起点向东');
      expect(restored.steps.first.cumulativeM, 300);
      expect(restored.steps.first.polyline, src.steps.first.polyline);
      // overlaps v2（标注离线可用）
      expect(restored.overlaps.length, 1);
      final OverlapGroup g = restored.overlaps.first;
      expect(g.refBearing, 91.5);
      expect(g.direction, 'reverse');
      expect(g.passes.length, 2);
      expect(g.passes[0].cumStartM, 300);
      expect(g.passes[1].cumEndM, 1220);
      expect(g.ranges.length, 2);
      // metrics（评分维度/质量指标离线展示）
      expect(restored.metrics['turns'], 17);
      expect(restored.metrics['turn_density'], 1.14);
      // score_components
      expect(restored.scoreComponents.first.name, '距离达标');
    });

    test('canStartRun 语义随往返保持', () {
      final PlannedRoute restored = PlannedRoute.fromJson(
        jsonDecode(jsonEncode(buildFull().toJson())) as Map<String, dynamic>,
      );
      expect(restored.canStartRun, isTrue);
    });

    test('二次往返稳定（幂等：toJson∘fromJson 不动点）', () {
      final PlannedRoute once = PlannedRoute.fromJson(
        jsonDecode(jsonEncode(buildFull().toJson())) as Map<String, dynamic>,
      );
      final PlannedRoute twice = PlannedRoute.fromJson(
        jsonDecode(jsonEncode(once.toJson())) as Map<String, dynamic>,
      );
      expect(twice.polyline, once.polyline);
      expect(twice.overlaps.first.passes[1].cumStartM,
          once.overlaps.first.passes[1].cumStartM);
      expect(twice.metrics, once.metrics);
    });
  });

  group('DeviceId 契约（规范⑧⑨）', () {
    test('首次生成：rl- 前缀 + 20 位随机尾段，且持久化', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DeviceId.debugResetCache();
      final String id = await DeviceId.get();
      expect(id, startsWith('rl-'));
      final List<String> parts = id.split('-');
      expect(parts.length, 3);
      expect(parts[2].length, 20);
      expect(parts[2], matches(RegExp(r'^[a-z0-9]{20}$')));
      // 已写入 SharedPreferences
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('runloop_device_id_v1'), id);
    });

    test('重装前稳定：清缓存重读返回同一 ID；peek 同步可用', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DeviceId.debugResetCache();
      final String id1 = await DeviceId.get();
      DeviceId.debugResetCache(); // 模拟进程重启（持久化仍在）
      final String id2 = await DeviceId.get();
      expect(id2, id1);
      expect(DeviceId.peek(), id1);
    });

    test('两台「设备」互不相同（随机性）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DeviceId.debugResetCache();
      final String a = await DeviceId.get();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DeviceId.debugResetCache();
      final String b = await DeviceId.get();
      expect(a, isNot(b));
    });
  });
}
