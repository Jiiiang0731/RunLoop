/// 导航状态机的显式状态（任务书 5.1：绝不用简单布尔值表达）。
enum NavStatus {
  /// 在规划路线上。
  onRoute,

  /// 疑似偏航：偏移超阈值但未满足「连续点数 + 持续时间」确认条件。
  possibleDeviation,

  /// 已确认偏航（多因子确认完成，等待/触发重规划）。
  offRoute,

  /// 重规划请求进行中（在飞；同一事件只允许一个请求）。
  rerouting,

  /// 重规划成功、新路线已生成（瞬态：原子接入后进入 onRoute）。
  rerouted,

  /// 重规划失败（无网络/后端不可用/无可行接入点），允许重试或跑回。
  rerouteFailed,
}

/// 偏航检测参数（任务书 5.2：可配置，不用单一固定阈值）。
///
/// 旧实现是「垂距 > 120m 即偏航」的单一布尔判断——过于迟钝且对
/// GPS 漂移过于敏感（两头不讨好）。新策略：
/// - 阈值随定位精度自适应：`accuracy × factor` 夹在 [min, max] 米——
///   精度好时用更小的判定范围（灵敏），精度差时放宽（防漂移误报）；
/// - 精度差于 [badAccuracyM] 的点不投票也不清票（跳点保护，5.7#1）；
/// - 连续 [confirmPoints] 个定位点 + 持续 [confirmDuration]（8–12s 区间）
///   才确认——单点漂移、瞬时跳变绝不触发；
/// - 行进方向与路线切线夹角 > [headingMismatchDeg] 时该点的偏移门槛降为
///   阈值×[mismatchOffsetFactor]（方向不匹配置信度：真的走反方向时
///   较小的横向偏移也算偏离票）。
class DeviationConfig {
  const DeviationConfig({
    this.minThresholdM = 25,
    this.maxThresholdM = 60,
    this.accuracyFactor = 2.0,
    this.badAccuracyM = 60,
    this.confirmPoints = 3,
    this.confirmDuration = const Duration(seconds: 8),
    this.headingMismatchDeg = 60,
    this.mismatchOffsetFactor = 0.6,
  });

  /// 精度好时的判定下限（米）。
  final double minThresholdM;

  /// 判定上限（米）——比旧值 120m 灵敏得多。
  final double maxThresholdM;
  final double accuracyFactor;

  /// 精度差于此值的点视为不可信（不参与投票）。
  final double badAccuracyM;
  final int confirmPoints;
  final Duration confirmDuration;
  final double headingMismatchDeg;
  final double mismatchOffsetFactor;

  /// 当前精度下的偏移判定阈值（米）。
  double thresholdFor(double accuracyM) =>
      (accuracyM * accuracyFactor).clamp(minThresholdM, maxThresholdM);

  DeviationConfig copyWith({
    double? minThresholdM,
    double? maxThresholdM,
    double? accuracyFactor,
    int? confirmPoints,
    Duration? confirmDuration,
  }) =>
      DeviationConfig(
        minThresholdM: minThresholdM ?? this.minThresholdM,
        maxThresholdM: maxThresholdM ?? this.maxThresholdM,
        accuracyFactor: accuracyFactor ?? this.accuracyFactor,
        badAccuracyM: badAccuracyM,
        confirmPoints: confirmPoints ?? this.confirmPoints,
        confirmDuration: confirmDuration ?? this.confirmDuration,
        headingMismatchDeg: headingMismatchDeg,
        mismatchOffsetFactor: mismatchOffsetFactor,
      );

  static const DeviationConfig defaults = DeviationConfig();
}

/// 偏航/重规划状态机（任务书 5.1–5.3、5.7）。
///
/// 只做状态判定与迁移，不发网络请求、不播语音——副作用全部由
/// 调用方（RunScreen）在 `update()` 返回迁移事件后驱动，可离线单测。
class NavStateMachine {
  NavStateMachine({this.config = DeviationConfig.defaults});

  final DeviationConfig config;

  NavStatus _status = NavStatus.onRoute;
  NavStatus get status => _status;

  DateTime? _devSince;
  int _devCount = 0;

  /// 当前是否处于「已确认离开路线」的宏观状态（UI/播报静默依据）。
  bool get isOffRoute =>
      _status == NavStatus.offRoute ||
      _status == NavStatus.rerouting ||
      _status == NavStatus.rerouteFailed;

  /// 每帧（~1Hz）喂入匹配结果；返回本次是否发生了状态迁移。
  ///
  /// [headingDeg]/[routeBearingDeg] 可空（无 GPS 航向或无法取路线切线时
  /// 只按偏移判定）。时钟注入便于单测。
  bool update({
    required double offsetM,
    required double accuracyM,
    double? headingDeg,
    double? routeBearingDeg,
    required DateTime now,
  }) {
    switch (_status) {
      case NavStatus.onRoute:
      case NavStatus.possibleDeviation:
        return _trackDeviation(
            offsetM: offsetM,
            accuracyM: accuracyM,
            headingDeg: headingDeg,
            routeBearingDeg: routeBearingDeg,
            now: now);
      case NavStatus.offRoute:
      case NavStatus.rerouting:
      case NavStatus.rerouteFailed:
        // 自然跑回：垂距回到当前精度的良好阈值内 → 直接回 onRoute
        //（在飞的重规划结果由调用方按状态丢弃，5.7#6）。
        if (accuracyM <= config.badAccuracyM &&
            offsetM <= config.thresholdFor(accuracyM)) {
          _status = NavStatus.onRoute;
          _resetVotes();
          return true;
        }
        return false;
      case NavStatus.rerouted:
        // 瞬态：等待调用方 acceptNewRoute()（新路线原子接入完成后）。
        return false;
    }
  }

  bool _trackDeviation({
    required double offsetM,
    required double accuracyM,
    required double? headingDeg,
    required double? routeBearingDeg,
    required DateTime now,
  }) {
    // 跳点保护（5.7#1）：坏精度点不投票、不清票、不改状态。
    if (accuracyM > config.badAccuracyM) return false;

    final double thr = config.thresholdFor(accuracyM);
    final bool mismatch = headingDeg != null &&
        routeBearingDeg != null &&
        _angDiff(headingDeg, routeBearingDeg) > config.headingMismatchDeg;
    final bool deviated =
        offsetM > thr || (mismatch && offsetM > thr * config.mismatchOffsetFactor);

    if (!deviated) {
      final bool was = _status == NavStatus.possibleDeviation;
      _resetVotes();
      if (was) {
        _status = NavStatus.onRoute;
        return true;
      }
      return false;
    }

    if (_status == NavStatus.onRoute) {
      _status = NavStatus.possibleDeviation;
      _devSince = now;
      _devCount = 1;
      return true;
    }

    // possibleDeviation：累计票数
    _devCount++;
    final Duration elapsed = now.difference(_devSince ?? now);
    if (_devCount >= config.confirmPoints && elapsed >= config.confirmDuration) {
      _status = NavStatus.offRoute;
      _resetVotes();
      return true;
    }
    return false;
  }

  // ---- 调用方驱动的显式迁移（重规划生命周期，5.7#5/#6） ----

  /// 发起重规划：仅 offRoute / rerouteFailed 可进入 rerouting
  /// （状态机级重规划锁——其他状态一律拒绝，防重复触发）。
  bool beginReroute() {
    if (_status != NavStatus.offRoute && _status != NavStatus.rerouteFailed) {
      return false;
    }
    _status = NavStatus.rerouting;
    return true;
  }

  /// 请求成功返回：rerouting → rerouted。
  bool rerouteSucceeded() {
    if (_status != NavStatus.rerouting) return false;
    _status = NavStatus.rerouted;
    return true;
  }

  /// 请求失败：rerouting → rerouteFailed。
  bool rerouteFailure() {
    if (_status != NavStatus.rerouting) return false;
    _status = NavStatus.rerouteFailed;
    return true;
  }

  /// 新路线已原子接入：rerouted → onRoute。
  bool acceptNewRoute() {
    if (_status != NavStatus.rerouted) return false;
    _status = NavStatus.onRoute;
    return true;
  }

  void _resetVotes() {
    _devSince = null;
    _devCount = 0;
  }

  static double _angDiff(double a, double b) {
    final double d = (a - b).abs() % 360.0;
    return d > 180.0 ? 360.0 - d : d;
  }
}

/// 弧度角差工具（供外部复用）。
double angleDiffDeg(double a, double b) {
  final double d = (a - b).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}
