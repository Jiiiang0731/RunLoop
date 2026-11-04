import 'package:flutter/material.dart';

import '../models/run_record.dart';
import '../utils/geo.dart';
import '../widgets/km_splits_table.dart';

/// 历史跑步详情页（阶段 L 模块 B）：汇总数据 + 每公里分段表（真实值）。
class RunDetailScreen extends StatelessWidget {
  const RunDetailScreen({super.key, required this.record});

  final RunRecord record;

  @override
  Widget build(BuildContext context) {
    final RunRecord r = record;
    return Scaffold(
      appBar: AppBar(title: Text('${_fmt(r.startTime)} 跑步详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _Item(label: '距离(公里)', value: formatKm(r.distanceMeters)),
              _Item(label: '总用时', value: formatDuration(r.durationSeconds)),
              _Item(label: '平均配速', value: formatPace(r.avgPaceSecondsPerKm)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _Item(label: '移动时长', value: formatDuration(r.movingSeconds)),
              _Item(label: '轨迹点', value: '${r.trackPoints.length}'),
              _Item(label: 'RPE', value: r.rpe?.toString() ?? '--'),
            ],
          ),
          if (r.note != null && r.note!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('备注'),
                subtitle: Text(r.note!),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text('每公里分段', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: KmSplitsTable(splits: r.kmSplits),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _Item extends StatelessWidget {
  const _Item({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }
}
