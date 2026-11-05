import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/services/nav/voice_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    VoiceLog.instance.debugClearForTest();
  });

  test('记录并按环形缓冲截断（cap=300）', () {
    for (int i = 0; i < 320; i++) {
      VoiceLog.instance
          .log(VoiceLogKind.speak, 'test', text: 'msg$i');
    }
    final List<VoiceLogEntry> e = VoiceLog.instance.entries;
    expect(e.length, VoiceLog.cap);
    expect(e.first.text, 'msg20'); // 最旧 20 条被挤出
    expect(e.last.text, 'msg319');
  });

  test('日志行格式：时间 [类型] 来源: 文本 | 附加', () {
    VoiceLog.instance.log(VoiceLogKind.done, 'tts',
        text: '前方五十米右转', detail: '首响 120ms');
    final String line = VoiceLog.instance.entries.last.line;
    expect(line, contains('[done]'));
    expect(line, contains('tts'));
    expect(line, contains('前方五十米右转'));
    expect(line, contains('首响 120ms'));
    expect(line, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} ')));
  });

  test('超长文本截断为 42 字 + 省略号', () {
    VoiceLog.instance
        .log(VoiceLogKind.speak, 'tts', text: '长' * 60);
    final String line = VoiceLog.instance.entries.last.line;
    expect(line, contains('…'));
    expect(line.length, lessThan(80));
  });

  test('会话持久化 round-trip：saveSession → loadLastSession', () async {
    VoiceLog.instance.log(VoiceLogKind.fgs, 'run', detail: '前台服务已启动');
    VoiceLog.instance
        .log(VoiceLogKind.lifecycle, 'run', detail: 'paused started=true');
    VoiceLog.instance
        .log(VoiceLogKind.speak, 'tts', text: '三', detail: 'flush');
    await VoiceLog.instance.saveSession();

    final List<VoiceLogEntry> loaded =
        await VoiceLog.instance.loadLastSession();
    expect(loaded.length, 3);
    expect(loaded[0].kind, VoiceLogKind.fgs);
    expect(loaded[1].detail, 'paused started=true');
    expect(loaded[2].text, '三');
  });

  test('无存档时 loadLastSession 返回空列表而非抛错', () async {
    expect(await VoiceLog.instance.loadLastSession(), isEmpty);
  });

  test('clearLastSession 后可再次读取为空', () async {
    VoiceLog.instance.log(VoiceLogKind.system, 'diag', detail: 'x');
    await VoiceLog.instance.saveSession();
    await VoiceLog.instance.clearLastSession();
    expect(await VoiceLog.instance.loadLastSession(), isEmpty);
  });

  test('toJson/fromJson 容错：未知 kind 归入 system，坏数据返回 null', () {
    final VoiceLogEntry? bad =
        VoiceLogEntry.fromJson(<String, dynamic>{'ts': 'not-a-date'});
    expect(bad, isNull);
    final VoiceLogEntry? ok = VoiceLogEntry.fromJson(<String, dynamic>{
      'ts': '2026-11-05T10:00:00.000',
      'kind': 'weirdKind',
      'source': 's',
    });
    expect(ok, isNotNull);
    expect(ok!.kind, VoiceLogKind.system);
  });
}
