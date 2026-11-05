import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/nav/tts_diagnostics.dart';
import '../services/nav/tts_service.dart';
import '../services/nav/voice_log.dart';

/// 语音引擎诊断页（阶段 M · Vivo TTS 专项，任务书七）。
///
/// 一键完成：设备/电源状态检查、已安装引擎枚举、逐引擎中文能力探测、
/// **真实普通话朗读测试**（不是只看初始化状态）、自动选择可用引擎、
/// 电池白名单与 Vivo 自启动引导、语音执行日志回看（含上一次锁屏会话）。
/// 所有信息不含账号、Key 等隐私，可整段复制反馈给开发者。
class VoiceDiagnosticsScreen extends StatefulWidget {
  const VoiceDiagnosticsScreen({super.key});

  @override
  State<VoiceDiagnosticsScreen> createState() => _VoiceDiagnosticsScreenState();
}

class _VoiceDiagnosticsScreenState extends State<VoiceDiagnosticsScreen> {
  final NativeTtsDiagnostics _diag = NativeTtsDiagnostics();
  final FlutterTtsEngine _tts = FlutterTtsEngine.shared;

  DevicePowerInfo? _device;
  List<TtsEngineInfo> _engines = const <TtsEngineInfo>[];
  String? _defaultPkg;
  String _via = '未检测';
  final Map<String, TtsProbeResult> _results = <String, TtsProbeResult>{};
  bool _busy = false;
  String _busyLabel = '';
  String? _autoPickReport;
  List<VoiceLogEntry>? _lastSession;
  bool _showLastSession = false;
  PermissionStatus _bgLocation = PermissionStatus.denied;

  // 锁屏语音自检：每 15s 真实朗读一次，共 8 次（约 2 分钟）。
  Timer? _selfTestTimer;
  bool _selfTestRunning = false;
  int _selfTestCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  Future<void> _refreshAll() async {
    setState(() {
      _busy = true;
      _busyLabel = '正在检测引擎…';
    });
    final DevicePowerInfo? info = await _diag.deviceInfo();
    final (List<TtsEngineInfo>, String?, String) engines =
        await _diag.listEngines();
    final PermissionStatus bg = await Permission.locationAlways.status;
    if (!mounted) return;
    setState(() {
      _device = info;
      _engines = engines.$1;
      _defaultPkg = engines.$2;
      _via = engines.$3;
      _bgLocation = bg;
      _busy = false;
    });
  }

  Future<void> _probe(TtsEngineInfo e, {bool speak = false}) async {
    setState(() {
      _busy = true;
      _busyLabel = speak ? '正在用「${e.label}」朗读测试…' : '正在探测「${e.label}」…';
    });
    VoiceLog.instance.log(VoiceLogKind.system, 'diag',
        detail: '${speak ? '朗读测试' : '探测'}引擎 ${e.pkg}');
    final TtsProbeResult r = speak
        ? await _diag.testSpeak(e.pkg)
        : await _diag.probeEngine(e.pkg);
    if (!mounted) return;
    setState(() {
      _results[e.pkg] = r;
      _busy = false;
    });
  }

  Future<void> _testCurrent() async {
    setState(() {
      _busy = true;
      _busyLabel = '正在用当前引擎朗读测试…';
    });
    final TtsProbeResult r = await _diag.testSpeak(_tts.enginePkg);
    if (!mounted) return;
    setState(() {
      _results[_tts.enginePkg ?? ''] = r;
      _busy = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.ok && r.stage == 'spoke'
            ? '朗读成功：${r.describe()}'
            : '朗读失败：${r.describe()}'),
      ));
    }
  }

  Future<void> _useEngine(TtsEngineInfo e) async {
    try {
      await _tts.applyEngine(e.pkg, logSource: 'diag');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已切换到「${e.label}」并持久化')));
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('切换失败：$err')));
      }
    }
  }

  /// 自动选择：逐引擎做真实朗读测试；优先「朗读成功 + 含离线中文 Voice」，
  /// 其次「朗读成功」（网络合成也可用，但提示锁屏断网风险）。
  Future<void> _autoSelect() async {
    if (_engines.isEmpty) {
      await _refreshAll();
    }
    if (_engines.isEmpty) {
      setState(() => _autoPickReport = '未找到任何系统 TTS 引擎。');
      return;
    }
    // 默认引擎排最前
    final List<TtsEngineInfo> order = <TtsEngineInfo>[
      ..._engines.where((TtsEngineInfo e) => e.pkg == _defaultPkg),
      ..._engines.where((TtsEngineInfo e) => e.pkg != _defaultPkg),
    ];
    TtsEngineInfo? fallback;
    for (int i = 0; i < order.length; i++) {
      final TtsEngineInfo e = order[i];
      if (!mounted) return;
      setState(() {
        _busy = true;
        _busyLabel = '自动选择：测试 ${i + 1}/${order.length}「${e.label}」…';
      });
      final TtsProbeResult r = await _diag.testSpeak(e.pkg);
      if (!mounted) return;
      setState(() => _results[e.pkg] = r);
      if (r.ok && r.stage == 'spoke' && r.zhSupported) {
        if (r.hasEmbeddedZh) {
          await _applyAutoPick(e, r, note: null);
          return;
        }
        fallback ??= e; // 网络合成引擎先记为备选，继续找离线的
      }
    }
    if (fallback != null) {
      await _applyAutoPick(fallback, _results[fallback.pkg]!,
          note: '注意：该引擎为网络合成，锁屏后若系统断网可能静音——'
              '请务必完成下方电池白名单与自启动放行。');
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _autoPickReport = '所有引擎的普通话朗读测试均未通过。\n'
          '这说明当前系统确实没有可用的中文语音能力（不是环跑的调用问题）。\n'
          '解决途径：系统设置 → 语言和输入法 → 文字转语音输出，为任一引擎'
          '下载「中文（普通话）」语音包；或安装官方语音引擎（如手机厂商语音服务/'
          'Google 语音服务）后回到本页重试。';
    });
  }

  Future<void> _applyAutoPick(
      TtsEngineInfo e, TtsProbeResult r, {String? note}) async {
    try {
      await _tts.applyEngine(e.pkg, logSource: 'diag');
    } catch (_) {
      // 切换失败仍报告测试结果
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _autoPickReport = '已自动选择「${e.label}」（${e.pkg}）并完成真实朗读验证：'
          '${r.describe()}${note == null ? '' : '\n$note'}';
    });
  }

  Future<void> _openBattery() async {
    final Map<String, dynamic> r = await _diag.openBatterySettings();
    VoiceLog.instance.log(VoiceLogKind.system, 'diag',
        detail: '电池设置跳转: $r');
  }

  Future<void> _openAutostart() async {
    final Map<String, dynamic> r = await _diag.openAutostartSettings();
    VoiceLog.instance.log(VoiceLogKind.system, 'diag',
        detail: '自启动设置跳转: $r');
    if (mounted && (r['ok'] != true)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('未找到厂商设置页，请手动进入 i管家 → 应用管理 → 权限 → 自启动')));
    }
  }

  Future<void> _requestBgLocation() async {
    final PermissionStatus s = await Permission.locationAlways.request();
    if (mounted) setState(() => _bgLocation = s);
  }

  /// 锁屏语音自检：开始后请立即锁屏，等待约 2 分钟再解锁查看日志。
  /// 每次朗读都会在 VoiceLog 留下 speak/start/done 或 6s/20s 看门狗错误，
  /// 据此可区分「没提交」「提交没出声」「出声没播完」。
  void _toggleSelfTest() {
    if (_selfTestRunning) {
      _selfTestTimer?.cancel();
      _selfTestTimer = null;
      setState(() => _selfTestRunning = false);
      VoiceLog.instance.log(VoiceLogKind.system, 'diag',
          detail: '锁屏语音自检已停止（已播 $_selfTestCount 次）');
      return;
    }
    setState(() {
      _selfTestRunning = true;
      _selfTestCount = 0;
    });
    VoiceLog.instance.log(VoiceLogKind.system, 'diag',
        detail: '锁屏语音自检开始：请立即锁屏，每 15s 播报一次，共 8 次');
    void speakOnce() {
      _selfTestCount++;
      unawaited(_tts.speak(
        '锁屏语音自检，第 $_selfTestCount 次。如果你听到这句话，说明锁屏语音正常。',
        flush: true,
      ));
      if (_selfTestCount >= 8) {
        _selfTestTimer?.cancel();
        _selfTestTimer = null;
        if (mounted) setState(() => _selfTestRunning = false);
        VoiceLog.instance.log(VoiceLogKind.system, 'diag',
            detail: '锁屏语音自检结束：请解锁后查看下方日志');
      }
    }
    speakOnce();
    _selfTestTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_selfTestRunning) return;
      speakOnce();
    });
  }

  @override
  void dispose() {
    _selfTestTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLastSession() async {
    final List<VoiceLogEntry> entries =
        await VoiceLog.instance.loadLastSession();
    if (!mounted) return;
    setState(() {
      _lastSession = entries;
      _showLastSession = true;
    });
  }

  Future<void> _copyLog() async {
    final StringBuffer sb = StringBuffer('=== 环跑语音诊断 ===\n');
    if (_device != null) {
      sb.write('设备: ${_device!.model} ${_device!.android}\n');
      sb.write('电池白名单: ${_device!.batteryWhitelisted ? '是' : '否'}'
          ' | 默认引擎: ${_device!.defaultEnginePkg ?? '?'}\n');
    }
    sb.write('引擎($_via): '
        '${_engines.map((TtsEngineInfo e) => '${e.label}[${e.pkg}]').join(', ')}\n');
    _results.forEach((String k, TtsProbeResult v) {
      sb.write('测试 $k => ${v.describe()}\n');
    });
    sb.write('--- 本次日志 ---\n${VoiceLog.instance.format()}\n');
    if (_lastSession != null && _lastSession!.isNotEmpty) {
      sb.write('--- 上次会话日志 ---\n');
      for (final VoiceLogEntry e in _lastSession!) {
        sb.write('${e.line}\n');
      }
    }
    await Clipboard.setData(ClipboardData(text: sb.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('诊断信息已复制（不含任何密钥）')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final DevicePowerInfo? dev = _device;
    return Scaffold(
      appBar: AppBar(title: const Text('语音引擎诊断')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (_busy)
            Card(
              color: Colors.blue.withAlpha(20),
              child: ListTile(
                leading: const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                title: Text(_busyLabel),
              ),
            ),
          // ---- 1. 设备与锁屏保障 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('设备与锁屏保障',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(dev == null
                      ? '正在读取设备信息…'
                      : '${dev.model} · ${dev.android}'
                          '${dev.isVivoLike ? ' · Vivo 系机型' : ''}'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: <Widget>[
                      _statusChip('电池白名单',
                          dev?.batteryWhitelisted ?? false ? '已放行' : '未放行',
                          ok: dev?.batteryWhitelisted ?? false),
                      _statusChip('省电模式', dev?.powerSave == true ? '开启中' : '关',
                          ok: dev?.powerSave != true),
                      _statusChip('后台定位权限', _bgLocation.isGranted ? '始终允许' : '未授予',
                          ok: _bgLocation.isGranted),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _openBattery,
                        icon: const Icon(Icons.battery_saver),
                        label: Text(dev?.batteryWhitelisted == true
                            ? '查看电池设置'
                            : '一键加入电池白名单'),
                      ),
                      const SizedBox(width: 8),
                      if (!_bgLocation.isGranted)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _requestBgLocation,
                          icon: const Icon(Icons.location_on),
                          label: const Text('授予后台定位'),
                        ),
                    ],
                  ),
                  if (dev?.isVivoLike ?? false) ...<Widget>[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _openAutostart,
                      icon: const Icon(Icons.phonelink_lock),
                      label: const Text('打开 Vivo 自启动/后台管理'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Vivo 锁屏静音的最常见原因是系统冻结后台：请允许环跑「自启动」，'
                      '并在 i管家 → 应用管理 → 环跑 → 耗电管理 中选择「无限制」，'
                      '同时关闭「锁屏后清理后台」类选项。完成后请锁屏实测一次语音。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ---- 2. 当前引擎 ----
          Card(
            child: ListTile(
              leading: const Icon(Icons.record_voice_over),
              title: const Text('环跑当前使用的引擎'),
              subtitle: Text(
                  '${_tts.enginePkg ?? _defaultPkg ?? '系统默认'}\n'
                  '测试语句：${NativeTtsDiagnostics.testText}',
                  style: const TextStyle(fontSize: 12)),
              trailing: FilledButton(
                onPressed: _busy ? null : _testCurrent,
                child: const Text('测试普通话'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ---- 2.5 锁屏语音自检 ----
          Card(
            color: _selfTestRunning ? Colors.orange.withAlpha(20) : null,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('锁屏语音自检',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  const Text(
                    '开始后请立即锁屏并等待约 2 分钟：App 每 15 秒真实朗读一次，'
                    '共 8 次。解锁后查看「语音执行日志」——每条会记录 '
                    'speak → start → done；若只有 speak 没有 start，会写入 6 秒'
                    '看门狗错误；若 start 后没有 done，会写入 20 秒看门狗错误。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: _toggleSelfTest,
                        icon: Icon(_selfTestRunning
                            ? Icons.stop_circle
                            : Icons.screen_lock_portrait),
                        label: Text(_selfTestRunning
                            ? '停止自检（已播 $_selfTestCount/8）'
                            : '开始锁屏语音自检'),
                      ),
                      const SizedBox(width: 8),
                      if (_selfTestRunning)
                        const Text('现在可以锁屏',
                            style: TextStyle(
                                color: Colors.deepOrange,
                                fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ---- 3. 引擎列表 ----
          Text('已安装引擎（$_via）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          if (_engines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('（未检测到引擎，请点击右上角刷新）',
                  style: TextStyle(color: Colors.grey)),
            ),
          for (final TtsEngineInfo e in _engines)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ExpansionTile(
                leading: const Icon(Icons.settings_voice),
                title: Row(
                  children: <Widget>[
                    Flexible(child: Text(e.label)),
                    if (e.pkg == _defaultPkg)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Chip(
                            label: Text('系统默认',
                                style: TextStyle(fontSize: 10)),
                            visualDensity: VisualDensity.compact),
                      ),
                    if (_tts.enginePkg == e.pkg)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Chip(
                            label: Text('环跑使用中',
                                style: TextStyle(fontSize: 10)),
                            visualDensity: VisualDensity.compact),
                      ),
                  ],
                ),
                subtitle: Text(e.pkg, style: const TextStyle(fontSize: 11)),
                children: <Widget>[
                  if (_results[e.pkg] != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(_results[e.pkg]!.describe(),
                            style: TextStyle(
                                fontSize: 12,
                                color: _results[e.pkg]!.ok
                                    ? Colors.green.shade700
                                    : Colors.deepOrange)),
                      ),
                    ),
                  if (_results[e.pkg]?.zhVoices.isNotEmpty ?? false)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _results[e.pkg]!.zhVoices
                              .map((Map<String, dynamic> v) =>
                                  '${v['locale']} ${v['name']} '
                                  '${(v['embedded'] as bool?) == true ? '离线' : ''}'
                                  '${(v['network'] as bool?) == true ? '网络' : ''}')
                              .join('\n'),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: <Widget>[
                        OutlinedButton(
                          onPressed: _busy ? null : () => _probe(e),
                          child: const Text('探测'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _probe(e, speak: true),
                          child: const Text('朗读测试'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _busy ? null : () => _useEngine(e),
                          child: const Text('使用此引擎'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _autoSelect,
            icon: const Icon(Icons.auto_fix_high),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('自动选择可用引擎（逐个真实朗读验证）'),
            ),
          ),
          if (_autoPickReport != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_autoPickReport!,
                  style: const TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 16),
          // ---- 4. 语音执行日志 ----
          Row(
            children: <Widget>[
              Text('语音执行日志', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton(
                  onPressed: _copyLog, child: const Text('复制全部诊断')),
            ],
          ),
          ListenableBuilder(
            listenable: VoiceLog.instance,
            builder: (BuildContext context, _) {
              final List<VoiceLogEntry> entries =
                  _showLastSession && _lastSession != null
                      ? _lastSession!
                      : VoiceLog.instance.entries;
              final List<VoiceLogEntry> view = entries.length > 80
                  ? entries.sublist(entries.length - 80)
                  : entries;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _showLastSession
                            ? '上一次会话（${view.length} 条）'
                            : '本次会话（${view.length} 条）',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      if (view.isEmpty)
                        const Text('（暂无日志——播放一次测试语音后出现）',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      for (final VoiceLogEntry e in view.reversed)
                        Text(e.line,
                            style: const TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                height: 1.5)),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              OutlinedButton(
                onPressed: _loadLastSession,
                child: const Text('载入上次会话日志（锁屏证据）'),
              ),
              const SizedBox(width: 8),
              if (_showLastSession)
                TextButton(
                  onPressed: () => setState(() => _showLastSession = false),
                  child: const Text('回到本次会话'),
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _busy ? null : _refreshAll,
        child: const Icon(Icons.refresh),
      ),
    );
  }

  Widget _statusChip(String label, String value, {required bool ok}) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(ok ? Icons.check_circle : Icons.warning_amber,
          size: 15, color: ok ? Colors.green : Colors.deepOrange),
      label: Text('$label: $value', style: const TextStyle(fontSize: 11)),
    );
  }
}
