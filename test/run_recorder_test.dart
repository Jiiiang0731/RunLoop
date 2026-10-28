import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/location_result.dart';
import 'package:runloop/services/run_recorder/run_recorder.dart';

LocationResult _loc(double lat, double lng, DateTime t) => LocationResult(
      latitude: lat,
      longitude: lng,
      accuracy: 5,
      speed: 0,
      locationType: 1,
      timestamp: t,
    );

void main() {
  test('累计距离与移动时长', () async {
    final StreamController<LocationResult> controller =
        StreamController<LocationResult>();
    final RunRecorder recorder = RunRecorder(stream: controller.stream);
    recorder.start();

    final DateTime t0 = DateTime(2024, 1, 1, 10, 0, 0);
    controller.add(_loc(31.0, 121.0, t0));
    controller.add(_loc(31.0, 121.001, t0.add(const Duration(seconds: 10))));

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(recorder.pointCount, 2);
    expect(recorder.distanceMeters, closeTo(95.4, 5));
    expect(recorder.movingSeconds, closeTo(10, 1));

    final record = recorder.end();
    expect(record, isNotNull);
    expect(record!.trackPoints.length, 2);
    await controller.close();
  });

  test('暂停/继续/结束状态机', () {
    final RunRecorder recorder = RunRecorder(
      stream: const Stream<LocationResult>.empty(),
    );
    recorder.start();
    expect(recorder.state, RunState.running);

    recorder.pause();
    expect(recorder.state, RunState.paused);

    recorder.resume();
    expect(recorder.state, RunState.running);

    recorder.end();
    expect(recorder.state, RunState.idle);
  });

  test('漂移点不累计距离', () async {
    final StreamController<LocationResult> controller =
        StreamController<LocationResult>();
    final RunRecorder recorder = RunRecorder(stream: controller.stream);
    recorder.start();

    final DateTime t0 = DateTime(2024, 1, 1, 10, 0, 0);
    controller.add(_loc(31.0, 121.0, t0));
    // 大跳点（0.01 经度约 950m）应被过滤
    controller.add(_loc(31.0, 121.01, t0.add(const Duration(seconds: 2))));

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(recorder.pointCount, 1); // 只有第一个点
    expect(recorder.distanceMeters, 0);
    recorder.end();
    await controller.close();
  });
}
