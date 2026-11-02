import 'package:flutter/material.dart';

import '../models/run_record.dart';
import '../services/storage/database.dart';
import '../utils/geo.dart';

/// 历史记录列表。
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<RunRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = AppDatabase.instance.getRuns();
  }

  void _reload() {
    setState(() {
      _future = AppDatabase.instance.getRuns();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('历史记录')),
      body: FutureBuilder<List<RunRecord>>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<List<RunRecord>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.error_outline, color: Colors.red, size: 40),
                    const SizedBox(height: 12),
                    Text('读取历史记录失败：${snap.error}'),
                    const SizedBox(height: 12),
                    FilledButton.tonal(onPressed: _reload, child: const Text('重试')),
                  ],
                ),
              ),
            );
          }
          final List<RunRecord> runs = snap.data ?? <RunRecord>[];
          if (runs.isEmpty) {
            return const Center(child: Text('还没有跑步记录'));
          }
          return ListView.builder(
            itemCount: runs.length + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index == 0) return _StatsHeader(runs: runs);
              final RunRecord r = runs[index - 1];
              return Dismissible(
                key: ValueKey<int>(r.id ?? index),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) async {
                  if (r.id != null) {
                    await AppDatabase.instance.deleteRun(r.id!);
                  }
                  _reload();
                },
                child: ListTile(
                  leading: const Icon(Icons.directions_run),
                  title: Text('${formatKm(r.distanceMeters)} 公里'),
                  subtitle: Text(
                    '${_fmt(r.startTime)} · ${formatDuration(r.durationSeconds)} · '
                    '配速 ${formatPace(r.avgPaceSecondsPerKm)}',
                  ),
                  trailing: r.rpe != null ? Text('RPE ${r.rpe}') : null,
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _fmt(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// 统计头部卡片（阶段 J）：总跑量 / 次数 / 本周 / 单次最长，全部由真实记录计算。
class _StatsHeader extends StatelessWidget {
  const _StatsHeader({required this.runs});

  final List<RunRecord> runs;

  @override
  Widget build(BuildContext context) {
    double totalM = 0;
    double weekM = 0;
    double maxM = 0;
    final DateTime now = DateTime.now();
    // 本周一 00:00
    final DateTime weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    for (final RunRecord r in runs) {
      totalM += r.distanceMeters;
      if (r.distanceMeters > maxM) maxM = r.distanceMeters;
      if (!r.startTime.isBefore(weekStart)) weekM += r.distanceMeters;
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF2979FF), Color(0xFF00B0FF)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: <BoxShadow>[
          BoxShadow(color: const Color(0xFF2979FF).withAlpha(70), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: <Widget>[
          _StatCell(value: formatKm(totalM), label: '总跑量(km)'),
          _StatCell(value: '${runs.length}', label: '总次数'),
          _StatCell(value: formatKm(weekM), label: '本周(km)'),
          _StatCell(value: formatKm(maxM), label: '最长(km)'),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(color: Colors.white.withAlpha(210), fontSize: 11)),
        ],
      ),
    );
  }
}
