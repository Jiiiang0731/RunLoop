import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/location_result.dart';
import '../../models/run_record.dart';
import '../../models/track_point.dart';
import '../../utils/geo.dart';
import '../location/location_service.dart';
import 'gps_filter.dart';

enum RunState { idle, running, paused }

/// GPS 跑步记录器：开始/暂停/继续/结束，累计轨迹、距离、配速与时长。
///
/// 纯逻辑 + 可注入定位流（便于单元测试）。定位生命周期由页面负责，
/// 本类只订阅 [stream]。
class RunRecorder extends ChangeNotifier {
  RunRecorder({Stream<LocationResult>? stream, GpsFilter? filter})
      : _stream = stream ?? LocationService.instance.stream,
        _filter = filter ?? const GpsFilter();

  final Stream<LocationResult> _stream;
  final GpsFilter _filter;
  StreamSubscription<LocationResult>? _sub;

  RunState _state = RunState.idle;
  Timer? _ticker; // 每秒通知 UI 刷新（保证计时实时更新，不依赖 GPS 回调）
  final List<TrackPoint> _points = [];
  TrackPoint? _lastPoint;
  DateTime? _startTime;
  DateTime? _segmentStart;
  double _accumulatedActiveSeconds = 0;
  double _movingSeconds = 0;
  double _distanceMeters = 0;

  RunState get state => _state;
  double get distanceMeters => _distanceMeters;
  int get pointCount => _points.length;
  List<TrackPoint> get points => List.unmodifiable(_points);

  /// 总时长（秒），不含暂停。
  int get durationSeconds {
    if (_state == RunState.idle) return _accumulatedActiveSeconds.round();
    final double active = _accumulatedActiveSeconds +
        (_segmentStart == null
            ? 0
            : DateTime.now().difference(_segmentStart!).inSeconds.toDouble());
    return active.round();
  }

  /// 移动时长（秒）。
  int get movingSeconds => _movingSeconds.round();

  /// 平均配速（秒/公里）。
  double? get avgPaceSecondsPerKm =>
      _distanceMeters > 10 ? _movingSeconds / (_distanceMeters / 1000) : null;

  /// 实时配速（秒/公里），基于最近 30 秒轨迹。
  double? get currentPaceSecondsPerKm {
    if (_points.length < 2) return null;
    final DateTime cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    final List<TrackPoint> recent =
        _points.where((p) => p.timestamp.isAfter(cutoff)).toList();
    if (recent.length < 2) return null;
    double d = 0;
    for (int i = 1; i < recent.length; i++) {
      d += haversineMeters(recent[i - 1].latitude, recent[i - 1].longitude,
          recent[i].latitude, recent[i].longitude);
    }
    final double dt = recent.last.timestamp
        .difference(recent.first.timestamp)
        .inSeconds
        .toDouble();
    if (dt <= 0 || d < 5) return null;
    return dt / (d / 1000);
  }

  void start() {
    if (_state != RunState.idle) return;
    _points.clear();
    _lastPoint = null;
    _distanceMeters = 0;
    _movingSeconds = 0;
    _accumulatedActiveSeconds = 0;
    _startTime = DateTime.now();
    _segmentStart = _startTime;
    _state = RunState.running;
    _sub = _stream.listen(_onLocation);
    // 每秒刷新一次 UI（运行中才刷新），避免没有 GPS 回调时计时停留在 0。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state == RunState.running) notifyListeners();
    });
    notifyListeners();
  }

  void _onLocation(LocationResult r) {
    if (_state != RunState.running) return;
    if (r.hasError) return; // 短时定位失败：跳过该点
    if (r.latitude == 0 && r.longitude == 0) return;
    final TrackPoint point = TrackPoint(
      latitude: r.latitude,
      longitude: r.longitude,
      accuracy: r.accuracy,
      speed: r.speed,
      timestamp: r.timestamp,
    );
    final GpsFilterDecision decision = _filter.evaluate(point, _lastPoint);
    if (!decision.accepted) return; // 漂移/跳点丢弃
    if (_lastPoint != null) {
      _distanceMeters += decision.distanceMeters;
      if (decision.isMoving) {
        _movingSeconds +=
            point.timestamp.difference(_lastPoint!.timestamp).inSeconds.toDouble();
      }
    }
    _points.add(point);
    _lastPoint = point;
    notifyListeners();
  }

  void pause() {
    if (_state != RunState.running || _segmentStart == null) return;
    _accumulatedActiveSeconds +=
        DateTime.now().difference(_segmentStart!).inSeconds.toDouble();
    _segmentStart = null;
    _state = RunState.paused;
    notifyListeners();
  }

  void resume() {
    if (_state != RunState.paused) return;
    _segmentStart = DateTime.now();
    _state = RunState.running;
    notifyListeners();
  }

  /// 结束跑步，返回本次记录（不负责持久化）。
  RunRecord? end() {
    if (_state == RunState.idle) return null;
    if (_state == RunState.running && _segmentStart != null) {
      _accumulatedActiveSeconds +=
          DateTime.now().difference(_segmentStart!).inSeconds.toDouble();
    }
    final DateTime endTime = DateTime.now();
    final DateTime startTime = _startTime ?? endTime;
    _state = RunState.idle;
    _segmentStart = null;
    _ticker?.cancel();
    _ticker = null;
    _sub?.cancel();
    _sub = null;

    final RunRecord record = RunRecord(
      startTime: startTime,
      endTime: endTime,
      durationSeconds: durationSeconds,
      movingSeconds: movingSeconds,
      distanceMeters: _distanceMeters,
      avgPaceSecondsPerKm: avgPaceSecondsPerKm ?? 0,
      trackPoints: List.of(_points),
    );
    notifyListeners();
    return record;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
