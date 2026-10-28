import 'dart:convert';

import 'track_point.dart';

/// 一次跑步记录。
class RunRecord {
  final int? id;
  final DateTime startTime;
  final DateTime? endTime;
  final int durationSeconds; // 总时长（不含暂停等待时间）
  final int movingSeconds; // 移动时长
  final double distanceMeters; // 距离（米）
  final double avgPaceSecondsPerKm; // 平均配速（秒/公里）
  final List<TrackPoint> trackPoints; // 实际 GPS 轨迹
  final List<List<double>>? plannedRoute; // 本次所选规划路线 [[lng,lat],...]，可为空
  final int? rpe; // 主观疲劳 1-10
  final String? note;

  const RunRecord({
    this.id,
    required this.startTime,
    this.endTime,
    required this.durationSeconds,
    required this.movingSeconds,
    required this.distanceMeters,
    required this.avgPaceSecondsPerKm,
    required this.trackPoints,
    this.plannedRoute,
    this.rpe,
    this.note,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'start_time': startTime.millisecondsSinceEpoch,
        'end_time': endTime?.millisecondsSinceEpoch,
        'duration_s': durationSeconds,
        'moving_s': movingSeconds,
        'distance_m': distanceMeters,
        'avg_pace': avgPaceSecondsPerKm,
        'track_points': jsonEncode(trackPoints.map((p) => p.toJson()).toList()),
        'planned_route': plannedRoute == null ? null : jsonEncode(plannedRoute),
        'rpe': rpe,
        'note': note,
      };

  factory RunRecord.fromMap(Map<String, dynamic> map) {
    final List<dynamic> rawPoints =
        jsonDecode(map['track_points'] as String) as List<dynamic>;
    List<List<double>>? planned;
    if (map['planned_route'] != null) {
      planned = (jsonDecode(map['planned_route'] as String) as List<dynamic>)
          .map((dynamic e) => <double>[
                ((e as List<dynamic>)[0] as num).toDouble(),
                (e[1] as num).toDouble(),
              ])
          .toList();
    }
    return RunRecord(
      id: map['id'] as int?,
      startTime: DateTime.fromMillisecondsSinceEpoch(map['start_time'] as int),
      endTime: map['end_time'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['end_time'] as int),
      durationSeconds: map['duration_s'] as int,
      movingSeconds: map['moving_s'] as int,
      distanceMeters: (map['distance_m'] as num).toDouble(),
      avgPaceSecondsPerKm: (map['avg_pace'] as num).toDouble(),
      trackPoints: rawPoints
          .map((dynamic p) => TrackPoint.fromJson(p as Map<String, dynamic>))
          .toList(),
      plannedRoute: planned,
      rpe: map['rpe'] as int?,
      note: map['note'] as String?,
    );
  }
}
