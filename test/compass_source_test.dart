import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/services/nav/compass_source.dart';
import 'package:runloop/services/nav/heading_controller.dart';

class FakeClock {
  DateTime now = DateTime(2026, 1, 1, 8);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

CompassEvent _evt(double? h) => CompassEvent.fromList(
    h == null ? null : <double>[h, h, 10]); // null 列表 → heading/accuracy 均 null

void main() {
  group('CompassSource（磁力计辅助源）', () {
    test('有效航向暴露；2 秒无数据过期为 null', () async {
      final StreamController<CompassEvent> sc =
          StreamController<CompassEvent>.broadcast();
      final FakeClock clk = FakeClock();
      final CompassSource src = CompassSource(
        eventsProvider: () => sc.stream,
        clock: clk.call,
      );
      src.start();
      sc.add(_evt(123.0));
      await Future<void>.delayed(Duration.zero);
      expect(src.heading, 123.0);
      expect(src.failed, isFalse);

      clk.advance(const Duration(seconds: 3));
      expect(src.heading, isNull); // 过期
      src.dispose();
      await sc.close();
    });

    test('非法值忽略；通道错误 → failed 降级，主流程不受影响', () async {
      final StreamController<CompassEvent> sc =
          StreamController<CompassEvent>.broadcast();
      final CompassSource src = CompassSource(eventsProvider: () => sc.stream);
      src.start();
      sc.add(_evt(null));
      sc.add(_evt(-5));
      sc.add(_evt(361));
      await Future<void>.delayed(Duration.zero);
      expect(src.heading, isNull);
      sc.addError(Exception('sensor gone'));
      await Future<void>.delayed(Duration.zero);
      expect(src.failed, isTrue);
      expect(src.heading, isNull);
      src.dispose();
      await sc.close();
    });

    test('无传感器机型：events 为 null → 静默降级', () {
      final CompassSource src = CompassSource(eventsProvider: () => null);
      src.start();
      expect(src.failed, isTrue);
      expect(src.heading, isNull);
      src.dispose();
    });
  });

  group('HeadingController 磁力计仅辅助（规范四.2/5）', () {
    test('静止且无路线方向 → 采纳磁力计，但用慢时间常数（比 GPS 平滑更钝）', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1); // 定向 90
      // 静止（0.1 m/s）、偏航无路线方向、磁力计 120
      final double? r = h.update(
        speed: 0.1,
        accuracy: 10,
        compassBearing: 120,
        dtSeconds: 1,
      );
      // tau=2.0 → alpha=0.393 → 前进约 11.8°（若误用 tau=0.8 会前进 21.3°）
      expect(r! - 90, greaterThan(5));
      expect(r - 90, lessThan(16));
      expect(r, lessThan(120));
    });

    test('静止但在路线上 → 路线切线优先于磁力计（更可靠）', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      final double? r = h.update(
        speed: 0.5, // ≥minSpeedRoute(0.4) 且 <compassMaxSpeed(0.6)
        accuracy: 10,
        routeBearing: 100,
        compassBearing: 300, // 若误用磁力计会向 300 转
        dtSeconds: 1,
      );
      expect(r! - 90, greaterThan(0));
      expect(r, lessThan(101)); // 向 100 收敛，与 300 无关
    });

    test('慢速移动（≥0.6）且无路线 → 磁力计不采纳，方向冻结', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      final double? r = h.update(
        speed: 0.8, // 走动中：磁力计被摆臂污染，不用
        accuracy: 10,
        compassBearing: 270,
        dtSeconds: 1,
      );
      expect(r, 90); // 冻结
    });

    test('跑动中 GPS 精度差 → 宁可冻结也不用磁力计（规范四.1）', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      final double? r = h.update(
        speed: 3,
        accuracy: 80, // 精度差
        gpsBearing: 180,
        compassBearing: 200,
        dtSeconds: 1,
      );
      expect(r, 90); // 冻结，不乱转
    });

    test('GPS 有效时永远压过磁力计', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 0, dtSeconds: 1);
      final double? r = h.update(
        speed: 3,
        accuracy: 10,
        gpsBearing: 45,
        compassBearing: 300,
        dtSeconds: 2,
      );
      expect(r! > 0 && r < 90, isTrue); // 向 45 收敛
    });
  });
}
