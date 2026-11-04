import 'package:flutter/material.dart';

import '../services/nav/nav_settings.dart';
import '../services/nav/tts_service.dart';

/// 语音导航设置页（阶段 L 模块 A，规范 2.5）。
///
/// - 导航播报开关 / 每公里配速播报开关（默认开）；
/// - 转弯提前提示距离（默认 50m）；
/// - 音量、语速调节；
/// - 试听按钮（真实 TTS 播放，与导航同一引擎与音频属性）；
/// - 中文 TTS 可用性自动诊断：缺引擎/缺中文语音数据时给出明确指引，
///   绝不静默失败（规范 2.5）。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final NavSettings _settings = NavSettings.instance;
  final FlutterTtsEngine _tts = FlutterTtsEngine();
  TtsDiagnostic? _diagnostic;
  bool _diagnosing = true;

  static const List<double> _distanceChoices = <double>[30, 50, 80, 100];

  @override
  void initState() {
    super.initState();
    _diagnose();
  }

  Future<void> _diagnose() async {
    setState(() => _diagnosing = true);
    await _settings.load();
    final TtsDiagnostic d = await _tts.diagnose();
    if (mounted) {
      setState(() {
        _diagnostic = d;
        _diagnosing = false;
      });
    }
  }

  Future<void> _testVoice() async {
    await _tts.configure(
      rate: _settings.speechRate,
      volume: _settings.volume,
    );
    await _tts.speak('语音测试：前方五十米右转，进入环城路', flush: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('语音导航设置')),
      body: ListenableBuilder(
        listenable: _settings,
        builder: (BuildContext context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            // ---- 引擎诊断 ----
            Card(
              color: _diagnostic == null || _diagnostic!.ok
                  ? null
                  : Colors.orange.withAlpha(28),
              child: ListTile(
                leading: _diagnosing
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : Icon(
                        _diagnostic?.ok ?? false
                            ? Icons.record_voice_over
                            : Icons.warning_amber_rounded,
                        color: _diagnostic?.ok ?? false
                            ? Colors.green
                            : Colors.deepOrange,
                      ),
                title: Text(_diagnosing
                    ? '正在检测语音引擎…'
                    : (_diagnostic?.ok ?? false ? '中文语音可用' : '语音不可用')),
                subtitle: _diagnostic == null
                    ? null
                    : Text(_diagnostic!.guidance),
                trailing: IconButton(
                  tooltip: '重新检测',
                  icon: const Icon(Icons.refresh),
                  onPressed: _diagnosing ? null : _diagnose,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('语音导航播报'),
              subtitle: const Text('转弯、偏航等导航提示（普通话）'),
              value: _settings.voiceNavEnabled,
              onChanged: (bool v) => _settings.setVoiceNavEnabled(v),
            ),
            SwitchListTile(
              title: const Text('每公里配速播报'),
              subtitle: const Text('「第 N 公里完成，本公里配速 X 分 Y 秒」'),
              value: _settings.kmPaceEnabled,
              onChanged: _settings.voiceNavEnabled
                  ? (bool v) => _settings.setKmPaceEnabled(v)
                  : null,
            ),
            const Divider(height: 32),
            // ---- 提前提示距离 ----
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('转弯提前提示距离：${_settings.announceDistanceM.toStringAsFixed(0)} 米',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                for (final double d in _distanceChoices)
                  ChoiceChip(
                    label: Text('${d.toStringAsFixed(0)} m'),
                    selected: _settings.announceDistanceM == d,
                    onSelected: (_) => _settings.setAnnounceDistanceM(d),
                  ),
              ],
            ),
            const Divider(height: 32),
            // ---- 音量 ----
            ListTile(
              title: const Text('音量'),
              subtitle: Slider(
                value: _settings.volume,
                divisions: 10,
                label: '${(_settings.volume * 100).round()}%',
                onChanged: (double v) => _settings.setVolume(v),
              ),
              trailing: Text('${(_settings.volume * 100).round()}%'),
            ),
            // ---- 语速 ----
            ListTile(
              title: const Text('语速'),
              subtitle: Slider(
                value: _settings.speechRate,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: _rateLabel(_settings.speechRate),
                onChanged: (double v) => _settings.setSpeechRate(v),
              ),
              trailing: Text(_rateLabel(_settings.speechRate)),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _testVoice,
              icon: const Icon(Icons.play_arrow),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('试听语音'),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '说明：使用手机系统自带语音引擎离线合成，不需要麦克风权限，'
              '不联网、无付费语音服务。播报会通过音频焦点与音乐共存'
              '（播报时音乐自动压低），并支持扬声器 / 有线耳机 / 蓝牙耳机。'
              '锁屏或应用在后台时，跑步前台服务保证播报继续。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  static String _rateLabel(double v) {
    if (v < 0.35) return '慢';
    if (v < 0.65) return '正常';
    if (v < 0.85) return '较快';
    return '快';
  }
}
