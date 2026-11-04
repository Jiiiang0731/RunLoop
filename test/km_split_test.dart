import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/location_result.dart';
import 'package:runloop/models/run_record.dart';
import 'package:runloop/models/track_point.dart';
import 'package:runloop/services/run_recorder/run_recorder.dart';

/// 1 米对应的纬度增量（haversine R=6371000 → 111194.93 m/度）。
const double _mPerDegLat = 111194.926;

class FakeClock {
  DateTime now = DateTime(2026, 1, 1, 8, 0, 0);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

LocationResult _north(double baseLat, double meters, DateTime t) => LocationResult(
      latitude: baseLat + meters / _mPerDegLat,
      longitude: 121.0,
      accuracy: 5,
      speed: 4,
      locationType: 1,
      timestamp: t,
      bearing: 0,
    );

void main() {
  test('整公里分段：1000m 边界插值 + 配速精确（规范 3.2#2）', () async {
    final StreamController<LocationResult> c = StreamController<LocationResult>();
    final FakeClock clk = FakeClock();
    final RunRecorder r = RunRecorder(stream: c.stream, clock: clk.call);
    r.start();

    // 每 1 秒前进 7m：第 142 点=994m，第 143 点=1001m → 边界在两点之间 6/7 处
    for (int i = 0; i <= 143; i++) {
      clk.advance(const Duration(seconds: 1));
      c.add(_north(31.0, i * 7.0, clk.now));
      await Future<void>.delayed(Duration.zero); // 让监听器按当时的假时钟消费
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(r.completedKm, 1);
    expect(r.kmSplits.length, 1);
    // 边界处活动秒 = 142 + 6/7 ≈ 142.857
    expect(r.kmSplits.first.seconds, closeTo(143.857, 0.3)); // 点 i 在 t0+(i+1) 到达
    expect(r.kmSplits.first.distanceM, 1000);
    expect(r.kmSplits.first.paceSecondsPerKm, closeTo(143.857, 0.3));
    r.end();
    await c.close();
  });

  test('暂停时间不计入分段（规范 3.2#6）', () async {
    final StreamController<LocationResult> c = StreamController<LocationResult>();
    final FakeClock clk = FakeClock();
    final RunRecorder r = RunRecorder(stream: c.stream, clock: clk.call);
    r.start();

    for (int i = 0; i <= 50; i++) {
      clk.advance(const Duration(seconds: 1));
      c.add(_north(31.0, i * 10.0, clk.now));
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    r.pause(); // t=51s，已跑 500m
    clk.advance(const Duration(seconds: 900)); // 暂停 15 分钟
    r.resume();
    for (int i = 51; i <= 100; i++) {
      clk.advance(const Duration(seconds: 1));
      c.add(_north(31.0, i * 10.0, clk.now));
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(r.completedKm, 1);
    // 活动秒 ≈ 50（暂停前）+ 50（恢复后），绝不是 950+
    expect(r.kmSplits.first.seconds, closeTo(100, 2));
    expect(r.kmSplits.first.seconds, lessThan(200));
    r.end();
    await c.close();
  });

  test('跳点被过滤，不产生虚假分段（规范 3.2#5）', () async {
    final StreamController<LocationResult> c = StreamController<LocationResult>();
    final FakeClock clk = FakeClock();
    final RunRecorder r = RunRecorder(stream: c.stream, clock: clk.call);
    r.start();

    clk.advance(const Duration(seconds: 1));
    c.add(_north(31.0, 0, clk.now));
    clk.advance(const Duration(seconds: 1));
    c.add(_north(31.0, 5000, clk.now)); // 5km 跳点 → GpsFilter 拒绝
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(r.pointCount, 1);
    expect(r.distanceMeters, 0);
    expect(r.kmSplits, isEmpty);
    r.end();
    await c.close();
  });

  test('GPS 丢失（距离不足 30m）不造分段（规范 3.2#5）', () async {
    final StreamController<LocationResult> c = StreamController<LocationResult>();
    final FakeClock clk = FakeClock();
    final RunRecorder r = RunRecorder(stream: c.stream, clock: clk.call);
    r.start();
    for (int i = 0; i <= 2; i++) {
      clk.advance(const Duration(seconds: 1));
      c.add(_north(31.0, i * 10.0, clk.now)); // 仅 20m
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final RunRecord? rec = r.end();
    expect(rec, isNotNull);
    expect(rec!.kmSplits, isEmpty); // 20m < 30m 末段阈值
    await c.close();
  });

  test('末段不足 1 公里单独记录 + 入库 JSON 往返（规范 3.2#9 / 3.3）', () async {
    final StreamController<LocationResult> c = StreamController<LocationResult>();
    final FakeClock clk = FakeClock();
    final RunRecorder r = RunRecorder(stream: c.stream, clock: clk.call);
    r.start();
    for (int i = 0; i <= 150; i++) {
      clk.advance(const Duration(seconds: 1));
      c.add(_north(31.0, i * 10.0, clk.now)); // 1500m
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final RunRecord? rec = r.end();
    expect(rec, isNotNull);
    expect(rec!.kmSplits.length, 2);
    expect(rec.kmSplits[0].index, 1);
    expect(rec.kmSplits[0].distanceM, 1000);
    expect(rec.kmSplits[0].seconds, closeTo(100, 2));
    expect(rec.kmSplits[1].index, 2);
    expect(rec.kmSplits[1].isPartial, isTrue);
    expect(rec.kmSplits[1].distanceM, closeTo(500, 1));
    expect(rec.kmSplits[1].paceSecondsPerKm, closeTo(100, 4)); // 50s/0.5km

    // 序列化往返（数据库 km_splits 列存 JSON）
    final Map<String, dynamic> map = rec.toMap();
    expect(map['km_splits'], isNotNull);
    final RunRecord back = RunRecord.fromMap(
      jsonDecode(jsonEncode(map)) as Map<String, dynamic>,
    );
    expect(back.kmSplits.length, 2);
    expect(back.kmSplits[1].isPartial, isTrue);
    expect(back.kmSplits[1].distanceM, closeTo(500, 1));
    await c.close();
  });

  test('旧记录（无 km_splits 列）解析为空列表（向后兼容）', () {
    final Map<String, dynamic> old = <String, dynamic>{
      'id': 1,
      'start_time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'end_time': null,
      'duration_s': 600,
      'moving_s': 590,
      'distance_m': 2000.0,
      'avg_pace': 300.0,
      'track_points': '[]',
      'planned_route': null,
      'rpe': null,
      'note': null,
      // 无 km_splits 键（v3 数据库行为）
    };
    final RunRecord r = RunRecord.fromMap(old);
    expect(r.kmSplits, isEmpty);
  });

  test('TrackPoint.bearing JSON 往返 + 旧轨迹无 brg 字段兼容', () {
    final TrackPoint modern = TrackPoint(
      latitude: 31,
      longitude: 121,
      accuracy: 5,
      speed: 3,
      timestamp: DateTime(2026),
      bearing: 87.5,
    );
    final TrackPoint back = TrackPoint.fromJson(modern.toJson());
    expect(back.bearing, 87.5);

    // 旧记录 JSON 无 brg → null（向后兼容）
    final TrackPoint legacy = TrackPoint.fromJson(<String, dynamic>{
      'lat': 31.0, 'lng': 121.0, 'acc': 5.0, 'spd': 3.0,
      't': DateTime(2026).millisecondsSinceEpoch,
    });
    expect(legacy.bearing, isNull);

    // 无 bearing 的新点不写入 brg 键（节省存储）
    expect(legacy.toJson().containsKey('brg'), isFalse);
  });

  test('LocationResult.bearing 仅 GPS 定位（locationType==1）时有效', () {
    final LocationResult gps = LocationResult.fromMap(<String, Object>{
      'latitude': 31.0, 'longitude': 121.0, 'accuracy': 8.0, 'speed': 3.0,
      'locationType': 1, 'bearing': 123.0,
      'locationTime': DateTime(2026).millisecondsSinceEpoch,
    });
    expect(gps.bearing, 123.0);

    // 网络定位的 bearing 是原生层假值 → 必须丢弃（规范 5.2：不盲信）
    final LocationResult net = LocationResult.fromMap(<String, Object>{
      'latitude': 31.0, 'longitude': 121.0, 'accuracy': 30.0, 'speed': 0.0,
      'locationType': 6, 'bearing': 90.0,
      'locationTime': DateTime(2026).millisecondsSinceEpoch,
    });
    expect(net.bearing, isNull);
  });
}
