import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/models/planned_route.dart';
import 'package:runloop/services/nav/nav_announcer.dart';
import 'package:runloop/services/nav/tts_service.dart';

class FakeEngine implements SpeechEngine {
  final List<String> spoken = <String>[];
  int stopCount = 0;
  bool speaking = false;

  @override
  void Function()? onIdle;

  @override
  bool get isSpeaking => speaking;

  @override
  Future<void> speak(String text, {required bool flush}) async {
    spoken.add(text);
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

  String get last => spoken.last;
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

RouteTurn _turn({
  String id = 't0',
  double atM = 500,
  String kind = 'right',
  double signedDeg = 90,
  String roadFrom = 'A路',
  String roadTo = 'B路',
  String confidence = 'high',
  bool announce = true,
  bool join = false,
}) =>
    RouteTurn(
      id: id,
      atM: atM,
      angleDeg: signedDeg.abs(),
      signedDeg: signedDeg,
      kind: kind,
      announce: announce,
      roadFrom: roadFrom,
      roadTo: roadTo,
      junction: const <double>[114.0, 30.5],
      stepIndex: 0,
      join: join,
      source: 'action+geometry',
      confidence: confidence,
    );

void main() {
  group('RouteTurn 契约', () {
    test('JSON 往返无损', () {
      final RouteTurn t = _turn(kind: 'left', signedDeg: -90);
      final RouteTurn back = RouteTurn.fromJson(t.toJson());
      expect(back.id, 't0');
      expect(back.atM, 500);
      expect(back.kind, 'left');
      expect(back.signedDeg, -90);
      expect(back.roadTo, 'B路');
      expect(back.confidence, 'high');
    });

    test('旧缓存无 turns → 由 steps.action 派生，左右不反转', () {
      final List<RouteStep> steps = <RouteStep>[
        const RouteStep(
            instruction: '', road: 'A路', distanceM: 100, cumulativeM: 100,
            action: 'left', orientation: '', polyline: <List<double>>[]),
        const RouteStep(
            instruction: '', road: 'B路', distanceM: 100, cumulativeM: 200,
            action: 'end', orientation: '', polyline: <List<double>>[]),
      ];
      final List<RouteTurn> turns = deriveTurnsFromSteps(steps);
      expect(turns[0].kind, 'left');
      expect(turns[0].atM, 100);
      expect(turns[1].kind, 'end');
    });

    test('PlannedRoute 从 JSON 解析 turns（不与 steps 各算一套）', () {
      final Map<String, dynamic> json = <String, dynamic>{
        'seed': 1,
        'distance_m': 1000,
        'polyline': <List<double>>[
          <double>[114.0, 30.5],
          <double>[114.001, 30.5],
        ],
        'steps': <dynamic>[],
        'turns': <dynamic>[_turn(kind: 'left', signedDeg: -90).toJson()],
      };
      final PlannedRoute r = PlannedRoute.fromJson(json);
      expect(r.turns.single.kind, 'left');
    });
  });

  group('P0 方向正确性：TTS 只消费 TurnEvent', () {
    test('90° 左转 → 前方左转，绝不右转', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'left', signedDeg: -90)]);
      e.spoken.clear();
      a.onPosition(alongM: 452, offRoute: false);
      expect(e.last, '前方 50米左转进入B路');
      expect(e.last.contains('右转'), isFalse);
    });

    test('90° 右转 → 前方右转', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'right', signedDeg: 90)]);
      e.spoken.clear();
      a.onPosition(alongM: 452, offRoute: false);
      expect(e.last, '前方 50米右转进入B路');
    });

    test('掉头 → 前方掉头', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'uturn', signedDeg: 180)]);
      e.spoken.clear();
      a.onPosition(alongM: 452, offRoute: false);
      expect(e.last, '前方 50米掉头进入B路');
    });
  });

  group('P0 播报时机', () {
    test('高速提前量更大：8m/s 在 70m 外即提示', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'right')]);
      e.spoken.clear();
      a.onPosition(alongM: 430, offRoute: false, speedMps: 8);
      expect(e.spoken, isNotEmpty);
      expect(e.last, contains('右转'));
    });

    test('低速不会过早打扰：2m/s 在 70m 外保持静默', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'right')]);
      e.spoken.clear();
      a.onPosition(alongM: 430, offRoute: false, speedMps: 2);
      expect(e.spoken, isEmpty);
      a.onPosition(alongM: 460, offRoute: false, speedMps: 2);
      expect(e.last, contains('右转'));
    });

    test('GPS 跳点越过转弯 40m → 不补播过期指令', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'right', atM: 500)]);
      e.spoken.clear();
      a.onPosition(alongM: 540, offRoute: false, speedMps: 4);
      expect(e.spoken, isEmpty, reason: '已越过 >30m，不得再播“现在右转”');
      a.onPosition(alongM: 545, offRoute: false, speedMps: 4);
      expect(e.spoken, isEmpty);
    });

    test('正常到位：越过前 8m 播一次“现在”且不重复', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'right', atM: 500)]);
      e.spoken.clear();
      a.onPosition(alongM: 495, offRoute: false, speedMps: 3);
      expect(e.spoken.where((String s) => s == '现在右转').length, 1);
      a.onPosition(alongM: 505, offRoute: false, speedMps: 3);
      expect(e.spoken.where((String s) => s == '现在右转').length, 1);
    });

    test('低置信度方向冲突 → 降级为一般提醒，不编造左右', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[
        _turn(kind: 'right', confidence: 'low', roadTo: '')
      ]);
      e.spoken.clear();
      a.onPosition(alongM: 452, offRoute: false);
      expect(e.last, '前方有路口，请按地图路线方向行进');
      expect(e.last.contains('右转'), isFalse);
      expect(e.last.contains('左转'), isFalse);
    });

    test('转弯里程与路线投影同一基准：atM 使用折线累计而不是步骤估算', () {
      final FakeEngine e = FakeEngine();
      final NavAnnouncer a = NavAnnouncer(engine: e, config: TestConfig());
      a.attachTurns(<RouteTurn>[_turn(kind: 'left', atM: 979)]);
      e.spoken.clear();
      // 旧服务端折线被抽稀到 991m、步骤却是 1076m；统一基准后 979m 才是
      // 真实转弯位置，929m 处应提前提示，而不是等到“快结束”。
      a.onPosition(alongM: 929, offRoute: false);
      expect(e.last, '前方 50米左转进入B路');
    });
  });
}
