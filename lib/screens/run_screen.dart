import 'package:flutter/material.dart';

import '../models/run_record.dart';
import '../services/run_recorder/run_recorder.dart';
import '../utils/geo.dart';
import 'run_summary_screen.dart';

/// 跑步中页面：实时距离/配速/时长，暂停/继续/结束。
class RunScreen extends StatefulWidget {
  const RunScreen({super.key});

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  final RunRecorder _recorder = RunRecorder();
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _recorder.start();
  }

  @override
  void dispose() {
    if (!_ending) {
      // 未正常结束时（返回键退出），也结束记录但不保存。
      _recorder.end();
    }
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _end() async {
    final RunRecord? record = _recorder.end();
    if (record == null) {
      Navigator.pop(context);
      return;
    }
    setState(() => _ending = true);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RunSummaryScreen(record: record),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跑步中'),
        automaticallyImplyLeading: false,
      ),
      body: ListenableBuilder(
        listenable: _recorder,
        builder: (BuildContext context, _) {
          final RunState state = _recorder.state;
          return Column(
            children: <Widget>[
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      formatKm(_recorder.distanceMeters),
                      style: const TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text('公里', style: TextStyle(fontSize: 18)),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        _Metric(
                          label: '实时配速',
                          value: formatPace(_recorder.currentPaceSecondsPerKm),
                        ),
                        _Metric(
                          label: '平均配速',
                          value: formatPace(_recorder.avgPaceSecondsPerKm),
                        ),
                        _Metric(
                          label: '总时长',
                          value: formatDuration(_recorder.durationSeconds),
                        ),
                        _Metric(
                          label: '移动时长',
                          value: formatDuration(_recorder.movingSeconds),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: <Widget>[
                    if (state == RunState.running)
                      FilledButton.tonalIcon(
                        onPressed: _recorder.pause,
                        icon: const Icon(Icons.pause),
                        label: const Text('暂停'),
                      )
                    else if (state == RunState.paused)
                      FilledButton.tonalIcon(
                        onPressed: _recorder.resume,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('继续'),
                      ),
                    FilledButton.icon(
                      onPressed: _end,
                      icon: const Icon(Icons.stop),
                      label: const Text('结束'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
      ],
    );
  }
}
