import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/planned_route.dart';
import 'package:runloop/services/nav/nav_announcer.dart';
import 'package:runloop/services/nav/tts_service.dart';
import 'package:runloop/models/km_split.dart';

/// 记录所有播报的假引擎。
class FakeEngine implements SpeechEngine {
  final List<String> spoken = <String>[];
  final List<bool> flushed = <bool>[]; // 与 spoken 对齐
  int stopCount = 0;
  bool speaking = false;

  @override
  void Function()? onIdle;

  @override
  bool get isSpeaking => speaking;

  @override
  Future<void> speak(String text, {required bool flush}) async {
    spoken.add(text);
    flushed.add(flush);
    speaking = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    speaking = false;
  }

  @override
  Future<void> configure({required double rate, required double volume}) async {}

  @override
  Future<TtsDiagnostic> diagnose() async =>
      const TtsDiagnostic(TtsAvailability.ok, '');

  /// 模拟一条语音播完（触发排队调度）。
  void finishSpeaking() {
    speaking = false;
    onIdle?.call();
  }

  String get last => spoken.last;
  bool containsOnce(String text) =>
      spoken.where((String s) => s == text).length == 1;
}

class TestConfig implements NavVoiceConfig {
  TestConfig({this.voiceNav = true, this.kmPace = true, this.announceM = 50});

  @override
  bool voiceNav;
  @override
  bool kmPace;
  @override
  double announceM;
}

/// 可控时钟。
class FakeClock {
  DateTime now = DateTime(2026, 1, 1, 8, 0, 0);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

RouteStep _step(String action, double cum, {String road = ''}) => RouteStep(
      instruction: '',
      road: road,
      distanceM: 100,
      cumulativeM: cum,
      action: action,
      orientation: '',
      polyline: const <List<double>>[],
    );

void main() {
  group('NavAnnouncer 转弯播报（规范 2.2/2.3）', () {
    test('出发提示带首条道路名', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[_step('straight', 100, road: '环城路'), _step('right', 500, road: '中山路')]);
      // 阶段 M-B：「开始跑步」由倒计时播报，attach 只排队出发方向信息
      expect(engine.last, '沿环城路前进');
    });

    test('提前 50m 播一次，窗口内不重复（防 GPS 抖动重播）', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[_step('right', 500, road: '中山路')]);
      engine.spoken.clear();

      a.onPosition(alongM: 400, offRoute: false);
      expect(engine.spoken, isEmpty); // 距转弯 100m > 50m

      a.onPosition(alongM: 452, offRoute: false);
      expect(engine.last, '前方 50米右转进入中山路');
      expect(engine.flushed.last, isTrue); // 转弯用打断队列

      a.onPosition(alongM: 455, offRoute: false);
      a.onPosition(alongM: 440, offRoute: false); // GPS 回跳
      a.onPosition(alongM: 458, offRoute: false);
      expect(engine.spoken.length, 1); // 只播一次
    });

    test('到位确认：越过转弯点前 8m 播「现在右转」', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[_step('right', 500)]);
      engine.spoken.clear(); // 忽略出发提示，只考察导航播报

      a.onPosition(alongM: 452, offRoute: false); // pre
      a.onPosition(alongM: 490, offRoute: false);
      expect(engine.spoken.where((String s) => s == '现在右转'), isEmpty);
      a.onPosition(alongM: 495, offRoute: false); // 越过 492 触发线
      expect(engine.containsOnce('现在右转'), isTrue);
      a.onPosition(alongM: 505, offRoute: false);
      expect(engine.spoken.where((String s) => s == '现在右转').length, 1);
    });

    test('连续近距转弯合并为一条（前方右转，随后左转）', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[
        _step('right', 500, road: 'A路'),
        _step('left', 530, road: 'B路'),
      ]);
      engine.spoken.clear();
      a.onPosition(alongM: 452, offRoute: false);
      expect(engine.last, '前方 50米右转进入A路，随后约 30米左转进入B路');
      // 第二转弯不再单独提前播报
      a.onPosition(alongM: 485, offRoute: false);
      expect(engine.spoken.length, 1);
      // 但各自都有到位确认
      a.onPosition(alongM: 495, offRoute: false);
      expect(engine.containsOnce('现在右转'), isTrue);
      a.onPosition(alongM: 520, offRoute: false);
      a.onPosition(alongM: 525, offRoute: false);
      expect(engine.containsOnce('现在左转'), isTrue);
    });

    test('直行步骤：路名不变不打扰，路名变化才提示一次', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[
        _step('straight', 300, road: 'A路'),
        _step('straight', 600, road: 'A路'),
        _step('straight', 900, road: 'B路'),
      ]);
      // attach 出发提示已含 A 路 → _lastRoad 由出发步骤置位？
      // 出发提示不改 _lastRoad（仅 straight pre 改），因此 300m 处会提示一次。
      a.onPosition(alongM: 255, offRoute: false);
      expect(engine.last, '沿A路继续直行');
      a.onPosition(alongM: 280, offRoute: false);
      expect(engine.spoken.where((String s) => s.contains('A路继续直行')).length, 1);

      a.onPosition(alongM: 555, offRoute: false); // 第二个直行：路名未变 → 静默
      expect(engine.spoken.where((String s) => s.contains('继续直行')).length, 1);

      a.onPosition(alongM: 855, offRoute: false); // 路名变化 → 提示
      expect(engine.last, '沿B路继续直行');
    });

    test('终点提示：接近 end 步骤播「已到达路线终点」一次', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[_step('right', 500), _step('end', 1000)]);
      engine.spoken.clear();
      a.onPosition(alongM: 975, offRoute: false);
      expect(engine.spoken, isEmpty); // 25m > 20m
      a.onPosition(alongM: 985, offRoute: false);
      expect(engine.containsOnce('已到达路线终点'), isTrue);
      a.onPosition(alongM: 995, offRoute: false);
      expect(engine.spoken.where((String s) => s == '已到达路线终点').length, 1);
    });
  });

  group('NavAnnouncer 偏航（规范 2.4#8）', () {
    test('偏航打断播报、期间静默并标记越过步骤、回归提示', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[_step('right', 500, road: 'A路'), _step('left', 800)]);
      engine.spoken.clear();

      a.onPosition(alongM: 452, offRoute: false);
      expect(engine.spoken.length, 1);

      a.onPosition(alongM: 460, offRoute: true); // 偏航开始
      expect(engine.last, '已偏离规划路线，请返回蓝色路线');
      expect(engine.flushed.last, isTrue);

      a.onPosition(alongM: 470, offRoute: true);
      a.onPosition(alongM: 510, offRoute: true); // 偏航期间越过 500m 步骤
      expect(engine.spoken.length, 2); // 静默：无转弯播报

      a.onPosition(alongM: 520, offRoute: false); // 回归
      expect(engine.last, '已回到规划路线');
      a.onPosition(alongM: 530, offRoute: false);
      // 越过的右转步骤不再补播（pre/now 均已标记）
      expect(engine.spoken.where((String s) => s.contains('右转')).length, 1);
    });
  });

  group('NavAnnouncer 暂停/继续/结束（规范 2.4#5/6/7）', () {
    test('暂停立即停止并静默；继续后重新武装下一条', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[_step('right', 500, road: 'A路')]);
      a.onPosition(alongM: 452, offRoute: false); // pre 已播
      engine.spoken.clear();

      a.onPause();
      expect(engine.stopCount, 1); // 暂停即停
      a.onPosition(alongM: 460, offRoute: false);
      expect(engine.spoken, isEmpty); // 暂停期间静默

      a.onResume(alongM: 460);
      a.onPosition(alongM: 460, offRoute: false); // 剩余 40m 仍在窗口 → 重播一次
      expect(engine.last, '前方 40米右转进入A路');
    });

    test('结束立即停止', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: engine, config: TestConfig());
      a.attach(<RouteStep>[]);
      engine.spoken.clear();
      a.onEnd();
      expect(engine.stopCount, 1);
    });

    test('总开关关闭时完全静默', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(
        engine: engine,
        config: TestConfig(voiceNav: false),
      );
      a.attach(<RouteStep>[_step('right', 500)]);
      engine.spoken.clear(); // 忽略出发提示，只考察导航播报
      a.onPosition(alongM: 452, offRoute: false);
      a.onPosition(alongM: 495, offRoute: false);
      expect(engine.spoken, isEmpty);
    });
  });

  group('NavAnnouncer 公里配速队列（规范 3.2#8 / 2.4）', () {
    test('空闲时直接播报', () {
      final FakeEngine engine = FakeEngine();
      final FakeClock clock = FakeClock();
      final NavAnnouncer a =
          NavAnnouncer(engine: engine, config: TestConfig(), clock: clock.call);
      a.attach(<RouteStep>[]);
      engine.spoken.clear();
      engine.speaking = false; // 出发提示已播完 → 引擎空闲
      a.onKmSplit(const KmSplit(index: 1, distanceM: 1000, seconds: 392));
      expect(engine.last, '第 1 公里完成，本公里配速 6 分 32 秒');
      expect(engine.flushed.last, isFalse); // 信息类不打断
    });

    test('转弯播报中 → 排队，空闲后补播', () {
      final FakeEngine engine = FakeEngine();
      final FakeClock clock = FakeClock();
      final NavAnnouncer a =
          NavAnnouncer(engine: engine, config: TestConfig(), clock: clock.call);
      a.attach(<RouteStep>[_step('right', 500)]);
      engine.spoken.clear(); // 忽略出发提示，只考察导航播报
      a.onPosition(alongM: 452, offRoute: false); // 转弯播报中
      expect(engine.speaking, isTrue);

      a.onKmSplit(const KmSplit(index: 1, distanceM: 1000, seconds: 300));
      expect(engine.spoken.length, 1); // 尚未插播

      clock.advance(const Duration(seconds: 4)); // 超过转弯静默期
      engine.finishSpeaking(); // 转弯播完 → 空闲
      expect(engine.last, '第 1 公里完成，本公里配速 5 分整');
    });

    test('过期公里语音自动丢弃（不积压）', () {
      final FakeEngine engine = FakeEngine();
      final FakeClock clock = FakeClock();
      final NavAnnouncer a =
          NavAnnouncer(engine: engine, config: TestConfig(), clock: clock.call);
      a.attach(<RouteStep>[_step('right', 500)]);
      engine.spoken.clear(); // 忽略出发提示，只考察导航播报
      a.onPosition(alongM: 452, offRoute: false);
      a.onKmSplit(const KmSplit(index: 1, distanceM: 1000, seconds: 300));
      clock.advance(const Duration(seconds: 20)); // > 15s 过期
      engine.finishSpeaking();
      expect(engine.spoken.length, 1); // 公里语音被丢弃
    });

    test('转弯静默期内空闲 → 丢弃排队公里（转弯优先）', () {
      final FakeEngine engine = FakeEngine();
      final FakeClock clock = FakeClock();
      final NavAnnouncer a =
          NavAnnouncer(engine: engine, config: TestConfig(), clock: clock.call);
      a.attach(<RouteStep>[_step('right', 500)]);
      engine.spoken.clear(); // 忽略出发提示，只考察导航播报
      a.onPosition(alongM: 452, offRoute: false); // T0 转弯
      a.onKmSplit(const KmSplit(index: 1, distanceM: 1000, seconds: 300));
      clock.advance(const Duration(seconds: 1)); // 仍在 3s 静默期
      engine.finishSpeaking(); // cancel 回调竞态：不插播
      expect(engine.spoken.length, 1);
    });

    test('配速开关关闭 → 不播公里', () {
      final FakeEngine engine = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(
        engine: engine,
        config: TestConfig(kmPace: false),
      );
      a.attach(<RouteStep>[]);
      engine.spoken.clear();
      a.onKmSplit(const KmSplit(index: 1, distanceM: 1000, seconds: 300));
      expect(engine.spoken, isEmpty);
    });
  });

  group('KmSplit 模型', () {
    test('JSON 往返一致', () {
      const KmSplit s = KmSplit(index: 3, distanceM: 1000, seconds: 355.4);
      final KmSplit back = KmSplit.fromJson(s.toJson());
      expect(back.index, 3);
      expect(back.distanceM, 1000);
      expect(back.seconds, closeTo(355.4, 1e-9));
      expect(back.paceSecondsPerKm, closeTo(355.4, 1e-9));
      expect(back.isPartial, isFalse);
    });

    test('末段不足 1 公里：标记 partial，配速按实际距离折算', () {
      const KmSplit s = KmSplit(index: 4, distanceM: 520, seconds: 200);
      expect(s.isPartial, isTrue);
      expect(s.paceSecondsPerKm, closeTo(200 / 0.52, 1e-6));
    });

    test('过短末段（<50m）不给出配速（避免噪声放大）', () {
      const KmSplit s = KmSplit(index: 4, distanceM: 32, seconds: 12);
      expect(s.paceSecondsPerKm, isNull);
      expect(s.announcement(), '第4公里完成');
    });

    test('播报文案：整分配「X 分整」', () {
      const KmSplit s = KmSplit(index: 2, distanceM: 1000, seconds: 360);
      expect(s.announcement(), '第 2 公里完成，本公里配速 6 分整');
    });
  });
}
