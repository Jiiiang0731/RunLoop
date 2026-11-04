import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/services/nav/nav_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    NavSettings.debugResetForTest();
  });

  test('默认值：导航开、公里配速开、提前 50m、正常语速、满音量（规范 2.5）', () async {
    await NavSettings.instance.load();
    final NavSettings s = NavSettings.instance;
    expect(s.voiceNavEnabled, isTrue);
    expect(s.kmPaceEnabled, isTrue);
    expect(s.announceDistanceM, 50);
    expect(s.speechRate, 0.5);
    expect(s.volume, 1.0);
    expect(s.loaded, isTrue);
  });

  test('设置持久化：写入后重新加载保持', () async {
    final NavSettings s = NavSettings.instance;
    await s.load();
    await s.setVoiceNavEnabled(false);
    await s.setKmPaceEnabled(false);
    await s.setAnnounceDistanceM(80);
    await s.setSpeechRate(0.7);
    await s.setVolume(0.4);

    NavSettings.debugResetForTest();
    await NavSettings.instance.load();
    final NavSettings s2 = NavSettings.instance;
    expect(s2.voiceNavEnabled, isFalse);
    expect(s2.kmPaceEnabled, isFalse);
    expect(s2.announceDistanceM, 80);
    expect(s2.speechRate, closeTo(0.7, 1e-9));
    expect(s2.volume, closeTo(0.4, 1e-9));
  });

  test('非法输入被 clamp 到安全范围', () async {
    final NavSettings s = NavSettings.instance;
    await s.load();
    await s.setAnnounceDistanceM(9999);
    expect(s.announceDistanceM, 150);
    await s.setAnnounceDistanceM(-5);
    expect(s.announceDistanceM, 20);
    await s.setSpeechRate(5);
    expect(s.speechRate, 1.0);
    await s.setVolume(-1);
    expect(s.volume, 0.0);
  });
}
