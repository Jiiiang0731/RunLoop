import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/widgets/countdown_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // HapticFeedback 走 SystemChannels.platform，测试中给空实现
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async => null);
  });

  Widget wrapCountdown(CountdownOverlay child) =>
      MaterialApp(home: Scaffold(body: Stack(children: <Widget>[child])));

  testWidgets('3→2→1→GO：GO 时刻触发 onGo，展示完触发 onComplete（规范 4.1/4.2）',
      (WidgetTester tester) async {
    int go = 0, complete = 0, cancel = 0;
    await tester.pumpWidget(wrapCountdown(CountdownOverlay(
      onGo: () => go++,
      onCancelled: () => cancel++,
      onComplete: () => complete++,
    )));

    expect(find.text('3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget);
    expect(go, 0); // 倒计时未结束绝不提前开始

    await tester.pump(const Duration(seconds: 1));
    expect(go, 1); // GO 时刻准确触发
    expect(find.text('GO!'), findsOneWidget);
    expect(complete, 0); // GO 还在展示

    await tester.pump(const Duration(milliseconds: 750));
    expect(complete, 1);
    expect(cancel, 0);
    await tester.pumpAndSettle(); // 无残留定时器/动画
  });

  testWidgets('取消：不触发 onGo，无残留', (WidgetTester tester) async {
    int go = 0, complete = 0, cancel = 0;
    await tester.pumpWidget(wrapCountdown(CountdownOverlay(
      onGo: () => go++,
      onCancelled: () => cancel++,
      onComplete: () => complete++,
    )));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(cancel, 1);
    expect(go, 0);
    expect(complete, 0);

    // 动画继续走完但不再回调（已取消）
    await tester.pump(const Duration(seconds: 4));
    expect(go, 0);
    expect(complete, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('快速退出（widget 移除）无异常无残留', (WidgetTester tester) async {
    await tester.pumpWidget(wrapCountdown(CountdownOverlay(
      onGo: () {},
      onCancelled: () {},
      onComplete: () {},
    )));
    await tester.pump(const Duration(milliseconds: 300));
    // 模拟用户立刻退出页面
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pumpAndSettle(); // 若控制器/定时器残留这里会报 pending timers
  });

  testWidgets('GO 后取消按钮禁用（防重复回调）', (WidgetTester tester) async {
    int cancel = 0;
    await tester.pumpWidget(wrapCountdown(CountdownOverlay(
      onGo: () {},
      onCancelled: () => cancel++,
      onComplete: () {},
    )));
    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    expect(find.text('GO!'), findsOneWidget);
    await tester.tap(find.text('取消'), warnIfMissed: false);
    await tester.pump();
    expect(cancel, 0);
    await tester.pumpAndSettle();
  });
}
