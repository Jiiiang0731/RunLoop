import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/services/nav/heading_controller.dart';

void main() {
  group('HeadingController 方向源仲裁（规范 5.2）', () {
    test('首帧可信 GPS 方向直接定向（无旋转动画）', () {
      final HeadingController h = HeadingController();
      final double? r = h.update(
          speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      expect(r, 90);
      expect(h.heading, 90);
    });

    test('静止/低速：冻结当前方向，不做无意义旋转', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      // 速度低于路线兜底阈值且无路线方向 → 冻结
      final double? r = h.update(speed: 0.1, accuracy: 10, gpsBearing: 270, dtSeconds: 1);
      expect(r, 90); // 不转向 270
    });

    test('精度差：不采用 GPS 方向（保护）', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      final double? r = h.update(
          speed: 3, accuracy: 80, gpsBearing: 180, dtSeconds: 1);
      expect(r, 90); // 精度 80 > 40 → 冻结（无路线兜底）
    });

    test('低速在路线上：用路线切线方向兜底', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      // 慢走 0.8 m/s（GPS 方向不可信阈值以下），路线方向 120
      final double? r = h.update(
          speed: 0.8, accuracy: 10, gpsBearing: null, routeBearing: 120, dtSeconds: 2);
      expect(r, isNot(90));
      // 朝 120 平滑趋近（未到达）
      expect(HeadingController.shortestDelta(90, r!).abs() < 30, isTrue);
      expect(HeadingController.shortestDelta(r, 120) >= 0, isTrue);
    });

    test('GPS 方向优先于路线方向（速度/精度达标时）', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 0, routeBearing: 180, dtSeconds: 1);
      expect(h.heading, 0); // 首帧直接采用 GPS
    });
  });

  group('HeadingController 平滑与环绕（规范 5.2#2/3）', () {
    test('最短弧：350° → 10° 走 +20° 而非 -340°', () {
      expect(HeadingController.shortestDelta(350, 10), closeTo(20, 1e-9));
      expect(HeadingController.shortestDelta(10, 350), closeTo(-20, 1e-9));
      // 180° 恰为最远点，±180 等价（约定返回 (-180, 180]）
      expect(HeadingController.shortestDelta(0, 180).abs(), closeTo(180, 1e-9));

      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 350, dtSeconds: 1);
      final double? r =
          h.update(speed: 3, accuracy: 10, gpsBearing: 10, dtSeconds: 1);
      // 结果应在 350 → 10 的顺时针短弧上（350..360/0..10）
      final double d = HeadingController.shortestDelta(350, r!);
      expect(d > 0 && d < 20, isTrue,
          reason: '应顺时针走短弧，实际 delta=$d, heading=$r');
    });

    test('指数平滑收敛：多次更新趋近目标并吸附', () {
      final HeadingController h = HeadingController(tauSeconds: 0.8);
      h.update(speed: 3, accuracy: 10, gpsBearing: 0, dtSeconds: 1);
      double last = 0;
      for (int i = 0; i < 10; i++) {
        last = h.update(speed: 3, accuracy: 10, gpsBearing: 60, dtSeconds: 0.5)!;
      }
      expect(last, 60); // 残差 <0.5° 时吸附到精确目标
      expect(h.heading, 60);
    });

    test('归一化：结果始终在 [0, 360)', () {
      final HeadingController h = HeadingController(tauSeconds: 0.05);
      h.update(speed: 3, accuracy: 10, gpsBearing: 10, dtSeconds: 1);
      for (final double t in <double>[350, 200, 0, 180]) {
        final double? r =
            h.update(speed: 3, accuracy: 10, gpsBearing: t, dtSeconds: 2);
        expect(r! >= 0 && r < 360, isTrue);
      }
    });

    test('dt<=0 不更新；reset 后重新定向', () {
      final HeadingController h = HeadingController();
      h.update(speed: 3, accuracy: 10, gpsBearing: 90, dtSeconds: 1);
      final double? r = h.update(speed: 3, accuracy: 10, gpsBearing: 180, dtSeconds: 0);
      expect(r, 90);
      h.reset();
      expect(h.heading, isNull);
      final double? r2 = h.update(speed: 3, accuracy: 10, gpsBearing: 180, dtSeconds: 1);
      expect(r2, 180); // 重新定向无动画
    });

    test('无效 bearing（负值/≥360/null）被忽略', () {
      final HeadingController h = HeadingController();
      expect(h.update(speed: 3, accuracy: 10, gpsBearing: -1, dtSeconds: 1), isNull);
      expect(h.update(speed: 3, accuracy: 10, gpsBearing: 360, dtSeconds: 1), isNull);
      expect(h.update(speed: 3, accuracy: 10, routeBearing: -5, dtSeconds: 1), isNull);
    });
  });
}
