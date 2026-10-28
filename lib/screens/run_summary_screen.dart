import 'package:flutter/material.dart';

import '../models/run_record.dart';
import '../services/storage/database.dart';
import '../utils/geo.dart';

/// 跑步总结页：展示本次数据，填写 RPE/备注后保存。
class RunSummaryScreen extends StatefulWidget {
  const RunSummaryScreen({super.key, required this.record});

  final RunRecord record;

  @override
  State<RunSummaryScreen> createState() => _RunSummaryScreenState();
}

class _RunSummaryScreenState extends State<RunSummaryScreen> {
  int _rpe = 5;
  final TextEditingController _noteController = TextEditingController();
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final RunRecord withMeta = RunRecord(
      startTime: widget.record.startTime,
      endTime: widget.record.endTime,
      durationSeconds: widget.record.durationSeconds,
      movingSeconds: widget.record.movingSeconds,
      distanceMeters: widget.record.distanceMeters,
      avgPaceSecondsPerKm: widget.record.avgPaceSecondsPerKm,
      trackPoints: widget.record.trackPoints,
      rpe: _rpe,
      note: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
    );
    await AppDatabase.instance.insertRun(withMeta);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
    Navigator.popUntil(context, (Route<dynamic> r) => r.isFirst);
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final RunRecord r = widget.record;
    final DateTime start = r.startTime;
    final DateTime? end = r.endTime;

    return Scaffold(
      appBar: AppBar(title: const Text('跑步总结')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _SummaryItem(label: '距离(公里)', value: formatKm(r.distanceMeters)),
              _SummaryItem(label: '总用时', value: formatDuration(r.durationSeconds)),
              _SummaryItem(label: '平均配速', value: formatPace(r.avgPaceSecondsPerKm)),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.timeline),
              title: const Text('轨迹点数'),
              trailing: Text('${r.trackPoints.length}'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('开始 / 结束'),
              subtitle: Text(
                '${_fmt(start)}${end != null ? ' ~ ${_fmt(end)}' : ''}',
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('主观疲劳 RPE：$_rpe', style: const TextStyle(fontSize: 16)),
          Slider(
            value: _rpe.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            label: '$_rpe',
            onChanged: (double v) => setState(() => _rpe = v.round()),
          ),
          TextField(
            controller: _noteController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('保存记录'),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[600])),
      ],
    );
  }
}
