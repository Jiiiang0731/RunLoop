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
          final List<RunRecord> runs = snap.data ?? <RunRecord>[];
          if (runs.isEmpty) {
            return const Center(child: Text('还没有跑步记录'));
          }
          return ListView.builder(
            itemCount: runs.length,
            itemBuilder: (BuildContext context, int index) {
              final RunRecord r = runs[index];
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
