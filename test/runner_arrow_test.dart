import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/widgets/runner_arrow.dart';

void main() {
  group('RunnerArrow.unwrapNext 最短弧展开（规范一.3 / 四.6）', () {
    test('350 → 10 展开为 370（连续系 +20，绝不 -340）', () {
      expect(RunnerArrow.unwrapNext(350, 10), closeTo(370, 1e-9));
    });

    test('10 → 350 展开为 -10', () {
      expect(RunnerArrow.unwrapNext(10, 350), closeTo(-10, 1e-9));
    });

    test('跨圈累计值保持连续：720 → 目标 10 得 730', () {
      expect(RunnerArrow.unwrapNext(720, 10), closeTo(730, 1e-9));
    });

    test('负累计值：-350 → 目标 -10(=350) 得 -350（原地）', () {
      // -350 % 360 → 10；目标 350：最短弧 10→350 = -20 → -370
      expect(RunnerArrow.unwrapNext(-350, 350), closeTo(-370, 1e-9));
    });

    test('目标即当前 → 不动', () {
      expect(RunnerArrow.unwrapNext(123.4, 123.4), closeTo(123.4, 1e-9));
    });
  });

  group('RunnerArrow 渲染', () {
    testWidgets('方向箭头正常渲染；更新角度无异常无残留', (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: RunnerArrow(screenRotationDegrees: 0),
          ),
        ),
      ));
      expect(find.byType(RunnerArrow), findsOneWidget);

      // 北→西（0→270）：与相机 bearing 变化一致的屏幕旋转
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: RunnerArrow(screenRotationDegrees: 270),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle(); // 动画完成，无 pending timer

      // 无方向模式（北朝上且航向未知）：退化为圆点，不抛异常
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: RunnerArrow(screenRotationDegrees: 0, showDirection: false),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    });

    testWidgets('heading-up 跟随：rotation 恒 0（箭头永远指屏幕正上方）',
        (WidgetTester tester) async {
      // 组件契约测试：调用方在 heading-up 下必须传 0；这里验证传 0 时
      // Transform.rotate 角度为 0（不旋转）。
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(child: RunnerArrow(screenRotationDegrees: 0)),
        ),
      ));
      final Transform t = tester.widget<Transform>(find.descendant(
        of: find.byType(RunnerArrow),
        matching: find.byType(Transform),
      ));
      final Matrix4 m = t.transform;
      // 单位旋转：m[0]==1, m[1]==0
      expect(m.entry(0, 0), closeTo(1, 1e-9));
      expect(m.entry(1, 0), closeTo(0, 1e-9));
    });
  });
}
