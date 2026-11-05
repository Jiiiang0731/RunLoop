import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/services/nav/tts_service.dart';
import 'package:runloop/widgets/countdown_overlay.dart';

/// 记录播报的假引擎（阶段 M-B 语音倒计时测试）。
class FakeSpeech implements SpeechEngine {
  final List<String> spoken = <String>[];
  final List<bool> flushes = <bool>[];
  int stopCalls = 0;
  bool failSpeak = false;

  @override
  Future<void> speak(String text, {required bool flush}) async {
    if (failSpeak) throw Exception('engine down');
    spoken.add(text);
    flushes.add(flush);
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> configure({required double rate, required double volume}) async {}

  @override
  Future<TtsDiagnostic> diagnose() async =>
      const TtsDiagnostic(TtsAvailability.ok, '');

  @override
  bool get isSpeaking => false;

  @override
  void Function()? onIdle;
}

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

  group('阶段 M-B 语音倒计时（任务书 3.1）', () {
    testWidgets('依次播报 三/二/一/开始跑步，全部 flush（语音不重叠）',
        (WidgetTester tester) async {
      final FakeSpeech engine = FakeSpeech();
      await tester.pumpWidget(wrapCountdown(CountdownOverlay(
        onGo: () {},
        onCancelled: () {},
        onComplete: () {},
        engine: engine,
      )));
      await tester.pump(); // 首帧 tick → 「三」
      expect(engine.spoken, <String>['三']);

      await tester.pump(const Duration(seconds: 1));
      expect(engine.spoken, <String>['三', '二']);
      await tester.pump(const Duration(seconds: 1));
      expect(engine.spoken, <String>['三', '二', '一']);
      await tester.pump(const Duration(seconds: 1));
      expect(engine.spoken, <String>['三', '二', '一', '开始跑步']);
      expect(engine.flushes.every((bool f) => f), isTrue,
          reason: '每句都必须 flush，前一句立即被打断清空——绝不重叠');
      await tester.pumpAndSettle();
    });

    testWidgets('「开始跑步」在 onGo 之前下发（出发播报 QUEUE_ADD 自然衔接）',
        (WidgetTester tester) async {
      final FakeSpeech engine = FakeSpeech();
      int spokenLenAtGo = -1;
      await tester.pumpWidget(wrapCountdown(CountdownOverlay(
        onGo: () => spokenLenAtGo = engine.spoken.length,
        onCancelled: () {},
        onComplete: () {},
        engine: engine,
      )));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1)); // GO 边界
      expect(spokenLenAtGo, 4, reason: 'onGo 触发时「开始跑步」必须已入队');
      expect(engine.spoken.last, '开始跑步');
      await tester.pumpAndSettle();
    });

    testWidgets('取消：清空语音队列（stop），此后不再播报，绝不触发 onGo',
        (WidgetTester tester) async {
      final FakeSpeech engine = FakeSpeech();
      int go = 0;
      await tester.pumpWidget(wrapCountdown(CountdownOverlay(
        onGo: () => go++,
        onCancelled: () {},
        onComplete: () {},
        engine: engine,
      )));
      await tester.pump();
      expect(engine.spoken, <String>['三']);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(engine.stopCalls, 1);
      expect(go, 0);
      await tester.pump(const Duration(seconds: 4));
      expect(engine.spoken, <String>['三'], reason: '取消后剩余语音不再播报');
      expect(go, 0);
      await tester.pumpAndSettle();
    });

    testWidgets('引擎异常：倒计时照常完成（静默降级为无语音，任务书 3.1#6）',
        (WidgetTester tester) async {
      final FakeSpeech engine = FakeSpeech()..failSpeak = true;
      int go = 0, complete = 0;
      await tester.pumpWidget(wrapCountdown(CountdownOverlay(
        onGo: () => go++,
        onCancelled: () {},
        onComplete: () => complete++,
        engine: engine,
      )));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(go, 1);
      expect(find.text('GO!'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 750));
      expect(complete, 1);
      await tester.pumpAndSettle();
    });
  });
}
