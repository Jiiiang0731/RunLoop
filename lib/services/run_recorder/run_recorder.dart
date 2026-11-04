import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/km_split.dart';
import '../../models/location_result.dart';
import '../../models/run_record.dart';
import '../../models/track_point.dart';
import '../../utils/geo.dart';
import '../location/location_service.dart';
import 'gps_filter.dart';

enum RunState { idle, running, paused }

/// GPS 跑步记录器：开始/暂停/继续/结束，累计轨迹、距离、配速与时长。
///
/// 阶段 L：新增每公里分段结算（规范 3.2）——
/// - 用**过滤后**的真实 GPS 累计距离，跨 1000m 边界按距离比例对
///   「运动秒」（排除暂停的活动时钟）做线性插值；
/// - 跳点已被 GpsFilter 拒绝，不会产生虚假分段；定位丢失期间没有
///   新点，也就没有分段（绝不用预估距离造假）；
/// - 结束时不足 1 公里的末段（≥30m）单独记录。
///
/// 纯逻辑 + 可注入定位流与时钟（便于单元测试）。定位生命周期由页面负责，
/// 本类只订阅 [stream]。
class RunRecorder extends ChangeNotifier {
  RunRecorder({
    Stream<LocationResult>? stream,
    GpsFilter? filter,
    DateTime Function()? clock,
  })  : _stream = stream ?? LocationService.instance.stream,
        _filter = filter ?? const GpsFilter(),
        _clock = clock ?? DateTime.now;

  final Stream<LocationResult> _stream;
  final GpsFilter _filter;
  final DateTime Function() _clock;
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

  // ---- 公里分段状态 ----
  final List<KmSplit> _kmSplits = [];
  double _nextBoundaryM = 1000; // 下一个完整公里边界
  double _splitStartActiveS = 0; // 当前分段起点的运动秒
  double _lastSampleActiveS = 0; // 上一接受点的运动秒（插值端点）

  RunState get state => _state;
  double get distanceMeters => _distanceMeters;
  int get pointCount => _points.length;
  List<TrackPoint> get points => List.unmodifiable(_points);

  /// 公里分段（含结束时的末段；跑步中实时增长）。
  List<KmSplit> get kmSplits => List.unmodifiable(_kmSplits);

  /// 已完成的**完整**公里数（UI/播报用：值变大 = 刚完成一公里）。
  int get completedKm => _kmSplits.where((KmSplit s) => !s.isPartial).length;

  /// 当前活动时钟（秒，排除暂停；高精度用于分段插值）。
  double _activeSecondsNow() =>
      _accumulatedActiveSeconds +
      (_segmentStart == null
          ? 0
          : _clock().difference(_segmentStart!).inMilliseconds / 1000.0);

  /// 总时长（秒），不含暂停。
  int get durationSeconds {
    if (_state == RunState.idle) return _accumulatedActiveSeconds.round();
    return _activeSecondsNow().round();
  }

  /// 移动时长（秒）。
  int get movingSeconds => _movingSeconds.round();

  /// 平均配速（秒/公里）。
  double? get avgPaceSecondsPerKm =>
      _distanceMeters > 10 ? _movingSeconds / (_distanceMeters / 1000) : null;

  /// 实时配速（秒/公里），基于最近 30 秒轨迹。
  double? get currentPaceSecondsPerKm {
    if (_points.length < 2) return null;
    final DateTime cutoff = _clock().subtract(const Duration(seconds: 30));
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
    _kmSplits.clear();
    _nextBoundaryM = 1000;
    _splitStartActiveS = 0;
    _lastSampleActiveS = 0;
    _startTime = _clock();
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
      bearing: r.bearing,
    );
    final GpsFilterDecision decision = _filter.evaluate(point, _lastPoint);
    if (!decision.accepted) return; // 漂移/跳点丢弃（公里分段因此天然免疫跳点）
    if (_lastPoint != null) {
      _distanceMeters += decision.distanceMeters;
      if (decision.isMoving) {
        _movingSeconds +=
            point.timestamp.difference(_lastPoint!.timestamp).inSeconds.toDouble();
      }
    }
    _points.add(point);
    _lastPoint = point;

    // ---- 公里分段结算：跨 1000m 边界按距离比例插值运动秒 ----
    final double activeNow = _activeSecondsNow();
    while (_distanceMeters >= _nextBoundaryM) {
      final double prevDist = _distanceMeters - decision.distanceMeters;
      final double frac = decision.distanceMeters <= 0
          ? 1.0
          : ((_nextBoundaryM - prevDist) / decision.distanceMeters).clamp(0.0, 1.0);
      final double boundaryActive =
          _lastSampleActiveS + (activeNow - _lastSampleActiveS) * frac;
      _kmSplits.add(KmSplit(
        index: _kmSplits.length + 1,
        distanceM: 1000,
        seconds:
            (boundaryActive - _splitStartActiveS).clamp(0.0, double.infinity),
      ));
      _splitStartActiveS = boundaryActive;
      _nextBoundaryM += 1000;
    }
    _lastSampleActiveS = activeNow;

    notifyListeners();
  }

  void pause() {
    if (_state != RunState.running || _segmentStart == null) return;
    _accumulatedActiveSeconds = _activeSecondsNow();
    _segmentStart = null;
    _state = RunState.paused;
    notifyListeners();
  }

  void resume() {
    if (_state != RunState.paused) return;
    _segmentStart = _clock();
    _state = RunState.running;
    notifyListeners();
  }

  /// 结束跑步，返回本次记录（不负责持久化）。
  RunRecord? end() {
    if (_state == RunState.idle) return null;
    if (_state == RunState.running && _segmentStart != null) {
      _accumulatedActiveSeconds = _activeSecondsNow();
    }
    final DateTime endTime = _clock();
    final DateTime startTime = _startTime ?? endTime;
    _state = RunState.idle;
    _segmentStart = null;
    _ticker?.cancel();
    _ticker = null;
    _sub?.cancel();
    _sub = null;

    // 末段不足 1 公里（≥30m）单独记录（规范 3.2#9）。
    final double rem = _distanceMeters - (_nextBoundaryM - 1000);
    if (rem >= 30) {
      _kmSplits.add(KmSplit(
        index: _kmSplits.length + 1,
        distanceM: rem,
        seconds:
            (_accumulatedActiveSeconds - _splitStartActiveS).clamp(0.0, double.infinity),
      ));
    }

    final RunRecord record = RunRecord(
      startTime: startTime,
      endTime: endTime,
      durationSeconds: durationSeconds,
      movingSeconds: movingSeconds,
      distanceMeters: _distanceMeters,
      avgPaceSecondsPerKm: avgPaceSecondsPerKm ?? 0,
      trackPoints: List.of(_points),
      kmSplits: List.of(_kmSplits),
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
