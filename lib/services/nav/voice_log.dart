import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 语音任务执行日志条目类型（任务书 2.3：提供语音任务的实际执行日志）。
enum VoiceLogKind {
  /// Dart 侧发起 speak。
  speak,

  /// 原生 onStart（真正开始出声）。
  start,

  /// 原生 onDone（完整播完）。
  done,

  /// 原生 onCancel/onStop（被打断）。
  cancel,

  /// 原生 onError / 异常。
  error,

  /// App 生命周期（前后台切换、锁屏推断）。
  lifecycle,

  /// 前台服务启停。
  fgs,

  /// 诊断/测试操作。
  system,
}

/// 一条日志：时间 + 类型 + 来源 + 文本摘要 + 附加信息。
class VoiceLogEntry {
  VoiceLogEntry({
    required this.ts,
    required this.kind,
    required this.source,
    this.text = '',
    this.detail,
  });

  final DateTime ts;
  final VoiceLogKind kind;

  /// 发起方：announcer / countdown / km / goal / diag / settings / run。
  final String source;
  final String text;
  final String? detail;

  String get timeLabel {
    final DateTime t = ts.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }

  String get line {
    final String t = text.length > 42 ? '${text.substring(0, 42)}…' : text;
    final String d = detail == null || detail!.isEmpty ? '' : ' | $detail';
    return '$timeLabel [${kind.name}] $source${t.isEmpty ? '' : ': $t'}$d';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': ts.toIso8601String(),
        'kind': kind.name,
        'source': source,
        'text': text,
        'detail': detail,
      };

  static VoiceLogEntry? fromJson(Map<String, dynamic> j) {
    try {
      return VoiceLogEntry(
        ts: DateTime.parse(j['ts'] as String),
        kind: VoiceLogKind.values.firstWhere(
          (VoiceLogKind k) => k.name == j['kind'],
          orElse: () => VoiceLogKind.system,
        ),
        source: (j['source'] as String?) ?? '?',
        text: (j['text'] as String?) ?? '',
        detail: j['detail'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 全局语音执行日志（环形缓冲，最多保留 [cap] 条）。
///
/// - 内存实时记录：每次 speak/start/done/cancel/error、生命周期切换、
///   前台服务启停——锁屏语音问题凭此还原时间线，不再靠猜；
/// - [saveSession] 在跑步结束/页面销毁时把本次日志写入
///   SharedPreferences，供「语音诊断」页回看上一次（锁屏）会话；
/// - 日志只含播报文本摘要与时间戳，不含位置、账号或任何密钥。
class VoiceLog extends ChangeNotifier {
  VoiceLog._();

  static final VoiceLog instance = VoiceLog._();

  static const int cap = 300;
  static const String _kLastSession = 'voice_log_last_session_v1';

  final List<VoiceLogEntry> _entries = <VoiceLogEntry>[];

  /// 全部日志（旧→新）。
  List<VoiceLogEntry> get entries => List<VoiceLogEntry>.unmodifiable(_entries);

  void log(
    VoiceLogKind kind,
    String source, {
    String text = '',
    String? detail,
  }) {
    _entries.add(VoiceLogEntry(
      ts: DateTime.now(),
      kind: kind,
      source: source,
      text: text,
      detail: detail,
    ));
    while (_entries.length > cap) {
      _entries.removeAt(0);
    }
    debugPrint('VoiceLog ${_entries.last.line}');
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String format() => _entries.map((VoiceLogEntry e) => e.line).join('\n');

  /// 持久化本次会话（跑步结束 / 诊断页手动）。
  Future<void> saveSession() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
        _kLastSession,
        jsonEncode(_entries.map((VoiceLogEntry e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('VoiceLog save failed: $e');
    }
  }

  /// 读取上一次会话日志（锁屏期间的时间线证据）。
  Future<List<VoiceLogEntry>> loadLastSession() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? raw = p.getString(_kLastSession);
      if (raw == null || raw.isEmpty) return const <VoiceLogEntry>[];
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((dynamic j) => VoiceLogEntry.fromJson(j as Map<String, dynamic>))
          .whereType<VoiceLogEntry>()
          .toList();
    } catch (e) {
      debugPrint('VoiceLog load failed: $e');
      return const <VoiceLogEntry>[];
    }
  }

  Future<void> clearLastSession() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(_kLastSession);
  }

  @visibleForTesting
  void debugClearForTest() => _entries.clear();
}
