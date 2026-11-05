/// P0：唯一转弯事实来源（服务端 TurnEvent 契约）。
///
/// 地图图标、顶部「下一转弯」和 TTS 必须全部消费本对象，禁止任何一端
/// 再根据屏幕坐标/地图旋转/自定义几何重算左右。
class RouteTurn {
  /// 稳定 id（同一路线多次重建不变）。
  final String id;

  /// 真实折线上的累计里程（米）——与 RoutePath/project 同一基准。
  final double atM;

  /// 转向角绝对值（度）。
  final double angleDeg;

  /// 有符号角差：+右 / -左（以实际行进方向为参照，与地图旋转无关）。
  final double signedDeg;

  /// left / right / uturn / straight / end。
  final String kind;

  /// 是否需要语音播报。
  final bool announce;

  final String roadFrom;
  final String roadTo;

  /// 路口坐标 [lng, lat]。
  final List<double> junction;
  final int stepIndex;

  /// true = 分段规划接缝处的折返（路线质量警示，不是屏幕方向问题）。
  final bool join;

  /// action+geometry / action / segment_join / geometry / road_change / end。
  final String source;

  /// high / medium / low。low 时客户端降级为一般方向提醒，避免编造左右。
  final String confidence;

  const RouteTurn({
    required this.id,
    required this.atM,
    required this.angleDeg,
    required this.signedDeg,
    required this.kind,
    required this.announce,
    required this.roadFrom,
    required this.roadTo,
    required this.junction,
    required this.stepIndex,
    required this.join,
    required this.source,
    required this.confidence,
  });

  bool get isTurn => kind == 'left' || kind == 'right' || kind == 'uturn';

  /// 方向不可靠时不允许播报具体左右（任务书 P0：可降级为一般提醒）。
  bool get directionReliable => kind != 'uturn' || confidence != 'low';

  factory RouteTurn.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawJ = (json['junction'] as List<dynamic>?) ?? <dynamic>[];
    return RouteTurn(
      id: json['id'] as String? ?? '',
      atM: (json['at_m'] as num?)?.toDouble() ?? 0,
      angleDeg: (json['angle_deg'] as num?)?.toDouble() ?? 0,
      signedDeg: (json['signed_deg'] as num?)?.toDouble() ?? 0,
      kind: json['kind'] as String? ?? 'straight',
      announce: json['announce'] as bool? ?? false,
      roadFrom: json['road_from'] as String? ?? '',
      roadTo: json['road_to'] as String? ?? '',
      junction: rawJ.map((dynamic e) => (e as num).toDouble()).toList(),
      stepIndex: (json['step_index'] as num?)?.toInt() ?? -1,
      join: json['join'] as bool? ?? false,
      source: json['source'] as String? ?? '',
      confidence: json['confidence'] as String? ?? 'low',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'at_m': atM,
        'angle_deg': angleDeg,
        'signed_deg': signedDeg,
        'kind': kind,
        'announce': announce,
        'road_from': roadFrom,
        'road_to': roadTo,
        'junction': junction,
        'step_index': stepIndex,
        'join': join,
        'source': source,
        'confidence': confidence,
      };
}

/// 旧缓存/旧服务端没有 turns 字段时的兼容派生。
///
/// 只使用步骤的 action + cumulative_m（结构化字段），不按地图箭头或屏幕
/// 方向猜测；没有 action 的步骤一律不生成转弯事件。
List<RouteTurn> deriveTurnsFromSteps(List<RouteStep> steps) {
  final List<RouteTurn> out = <RouteTurn>[];
  String lastRoad = '';
  for (int i = 0; i < steps.length; i++) {
    final RouteStep s = steps[i];
    final String kind = s.action;
    final bool isEnd = kind == 'end';
    final bool isTurn = kind == 'left' || kind == 'right' || kind == 'uturn';
    final bool roadChanged = s.road.isNotEmpty && s.road != lastRoad;
    if (s.road.isNotEmpty) {
      lastRoad = s.road;
    }
    if (!isTurn && !isEnd && !(kind == 'straight' && roadChanged)) {
      continue;
    }
    final List<double> junction = s.polyline.isEmpty
        ? const <double>[]
        : <double>[s.polyline.last[0], s.polyline.last[1]];
    // 兼容旧字段语义：旧后端把「当前步骤道路」放在 road 上，步骤列表里
    // 没有可靠的目标道路，因此这里沿用 step.road；新后端 turns 使用真实
    // road_to，不受此兼容逻辑影响。
    final String road = s.road;
    out.add(RouteTurn(
      id: 'legacy-t$i',
      atM: s.cumulativeM,
      angleDeg: 0,
      signedDeg: 0,
      kind: kind,
      announce: isTurn || kind == 'straight',
      roadFrom: road,
      roadTo: road,
      junction: junction,
      stepIndex: i,
      join: false,
      source: kind == 'straight' ? 'legacy_road_change' : 'legacy_step_action',
      confidence: 'medium',
    ));
  }
  return out;
}

/// 一步导航指令。
class RouteStep {
  final String instruction;
  final String road;
  final double distanceM;
  final double cumulativeM;
  final String action;
  final String orientation;
  final List<List<double>> polyline;

  const RouteStep({
    required this.instruction,
    required this.road,
    required this.distanceM,
    required this.cumulativeM,
    required this.action,
    required this.orientation,
    required this.polyline,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'instruction': instruction,
        'road': road,
        'distance_m': distanceM,
        'cumulative_m': cumulativeM,
        'action': action,
        'orientation': orientation,
        'polyline': polyline,
      };

  factory RouteStep.fromJson(Map<String, dynamic> json) {
    final List<dynamic> raw = (json['polyline'] as List<dynamic>?) ?? <dynamic>[];
    return RouteStep(
      instruction: json['instruction'] as String? ?? '',
      road: json['road'] as String? ?? '',
      distanceM: (json['distance_m'] as num?)?.toDouble() ?? 0,
      cumulativeM: (json['cumulative_m'] as num?)?.toDouble() ?? 0,
      action: json['action'] as String? ?? '',
      orientation: json['orientation'] as String? ?? '',
      polyline: raw
          .map((dynamic e) => <double>[
                (e[0] as num).toDouble(),
                (e[1] as num).toDouble(),
              ])
          .toList(),
    );
  }
}

/// 重复路段区间（v1 兼容字段；阶段 K 起折线不做视觉偏移，仅供标注定位）。
class OverlapRange {
  final int start;
  final int end;
  final double offset;

  const OverlapRange({required this.start, required this.end, required this.offset});

  factory OverlapRange.fromJson(Map<String, dynamic> json) => OverlapRange(
        start: (json['start'] as num).toInt(),
        end: (json['end'] as num).toInt(),
        offset: (json['offset'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start': start,
        'end': end,
        'offset': offset,
      };
}

/// 一次经过（pass）：同一道路第 N 次通过的点区间与累计里程区间（阶段 K v2）。
class OverlapPass {
  final int pass; // 1 = 先去程，2 = 后返程（按经过顺序）
  final int start; // 点下标（含）
  final int end; // 点下标（不含）
  final double cumStartM;
  final double cumEndM;

  const OverlapPass({
    required this.pass,
    required this.start,
    required this.end,
    required this.cumStartM,
    required this.cumEndM,
  });

  factory OverlapPass.fromJson(Map<String, dynamic> json) => OverlapPass(
        pass: (json['pass'] as num?)?.toInt() ?? 1,
        start: (json['start'] as num).toInt(),
        end: (json['end'] as num).toInt(),
        cumStartM: (json['cum_start_m'] as num?)?.toDouble() ?? 0,
        cumEndM: (json['cum_end_m'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pass': pass,
        'start': start,
        'end': end,
        'cum_start_m': cumStartM,
        'cum_end_m': cumEndM,
      };

  double get lengthM => cumEndM - cumStartM;
  int get midIndex => (start + end) ~/ 2;
}

/// 一组重复路段（同一道路被两次经过）。
class OverlapGroup {
  final double refBearing;

  /// "reverse" = 两次经过方向相反（去/返程）；"forward" = 同向重复。
  final String direction;
  final List<OverlapRange> ranges;

  /// v2 字段：带 pass 序号与累计里程（旧后端数据缺省时由 ranges 派生）。
  final List<OverlapPass> passes;

  const OverlapGroup({
    required this.refBearing,
    required this.ranges,
    this.direction = 'reverse',
    this.passes = const <OverlapPass>[],
  });

  factory OverlapGroup.fromJson(Map<String, dynamic> json) {
    final List<OverlapRange> ranges =
        ((json['ranges'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic e) => OverlapRange.fromJson(e as Map<String, dynamic>))
            .toList();
    List<OverlapPass> passes = ((json['passes'] as List<dynamic>?) ?? <dynamic>[])
        .map((dynamic e) => OverlapPass.fromJson(e as Map<String, dynamic>))
        .toList();
    if (passes.isEmpty && ranges.length == 2) {
      // 兼容 v1 数据：无累计里程，仅点区间
      passes = <OverlapPass>[
        OverlapPass(pass: 1, start: ranges[0].start, end: ranges[0].end,
            cumStartM: 0, cumEndM: 0),
        OverlapPass(pass: 2, start: ranges[1].start, end: ranges[1].end,
            cumStartM: 0, cumEndM: 0),
      ];
    }
    return OverlapGroup(
      refBearing: (json['ref_bearing'] as num?)?.toDouble() ?? 0,
      direction: json['direction'] as String? ?? 'reverse',
      ranges: ranges,
      passes: passes,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ref_bearing': refBearing,
        'direction': direction,
        'ranges': ranges.map((OverlapRange r) => r.toJson()).toList(),
        'passes': passes.map((OverlapPass p) => p.toJson()).toList(),
      };
}

/// 单条候选规划路线。
class PlannedRoute {
  final int seed;
  final double distanceM;
  final double errorM;
  final bool withinTolerance;
  final double closureM;
  final bool closureOk;
  final double? score;
  final int nPoints;
  final List<List<double>> polyline; // [[lng, lat], ...]（GCJ-02）
  final List<ScoreItem> scoreComponents;
  final List<RouteStep> steps;
  /// P0：统一转弯事件（服务端 turns）；旧缓存缺省时由 steps.action 派生。
  final List<RouteTurn> turns;
  final List<OverlapGroup> overlaps;
  /// 路线质量指标（turns / turn_density / straight_max_m / repetition_ratio ...）。
  final Map<String, dynamic> metrics;
  /// 后端评分排序后的最优达标候选（阶段 J）。
  final bool recommended;

  const PlannedRoute({
    required this.seed,
    required this.distanceM,
    required this.errorM,
    required this.withinTolerance,
    required this.closureM,
    required this.closureOk,
    required this.score,
    required this.nPoints,
    required this.polyline,
    required this.scoreComponents,
    required this.steps,
    this.turns = const <RouteTurn>[],
    this.overlaps = const <OverlapGroup>[],
    this.metrics = const <String, dynamic>{},
    this.recommended = false,
  });

  /// 该路线是否可安全进入跑步流程（距离达标 + 闭合达标）。
  bool get canStartRun => withinTolerance && closureOk;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'seed': seed,
        'distance_m': distanceM,
        'error_m': errorM,
        'within_tolerance': withinTolerance,
        'closure_m': closureM,
        'closure_ok': closureOk,
        'score': score,
        'n_points': nPoints,
        'polyline': polyline,
        'recommended': recommended,
        // 阶段 K（离线完整性）：overlaps/metrics 一并入库，
        // 无网时标注与指标展示不丢信息。
        'overlaps': overlaps.map((OverlapGroup g) => g.toJson()).toList(),
        'metrics': metrics,
        'score_components': scoreComponents
            .map((ScoreItem s) => <String, dynamic>{
                  'name': s.name,
                  'score': s.score,
                  'weight': s.weight,
                  'available': s.available,
                  'detail': s.detail,
                })
            .toList(),
        'steps': steps.map((RouteStep s) => s.toJson()).toList(),
        'turns': turns.map((RouteTurn t) => t.toJson()).toList(),
      };

  factory PlannedRoute.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawPoly = (json['polyline'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> rawScore = (json['score_components'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> rawSteps = (json['steps'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> rawTurns = (json['turns'] as List<dynamic>?) ?? <dynamic>[];
    final double errorM = (json['error_m'] as num?)?.toDouble() ?? 0;
    final List<RouteStep> steps = rawSteps
        .map((dynamic e) => RouteStep.fromJson(e as Map<String, dynamic>))
        .toList();
    // 旧缓存/旧后端无 turns：从结构化 steps.action 派生（不猜屏幕方向）。
    final List<RouteTurn> turns = rawTurns.isNotEmpty
        ? rawTurns
            .map((dynamic e) => RouteTurn.fromJson(e as Map<String, dynamic>))
            .toList()
        : deriveTurnsFromSteps(steps);
    return PlannedRoute(
      seed: json['seed'] as int,
      distanceM: (json['distance_m'] as num?)?.toDouble() ?? 0,
      errorM: errorM,
      withinTolerance: json['within_tolerance'] as bool? ?? (errorM.abs() <= 500),
      closureM: (json['closure_m'] as num?)?.toDouble() ?? 0,
      closureOk: json['closure_ok'] as bool? ?? true,
      score: (json['score'] as num?)?.toDouble(),
      nPoints: (json['n_points'] as num?)?.toInt() ?? 0,
      polyline: rawPoly
          .map((dynamic e) => <double>[
                (e[0] as num).toDouble(),
                (e[1] as num).toDouble(),
              ])
          .toList(),
      scoreComponents: rawScore
          .map((dynamic e) => ScoreItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      steps: steps,
      turns: turns,
      overlaps: ((json['overlaps'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic e) => OverlapGroup.fromJson(e as Map<String, dynamic>))
          .toList(),
      metrics: (json['metrics'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      recommended: json['recommended'] as bool? ?? false,
    );
  }
}

/// 评分维度。
class ScoreItem {
  final String name;
  final double? score;
  final double weight;
  final bool available;
  final String detail;

  const ScoreItem({
    required this.name,
    required this.score,
    required this.weight,
    required this.available,
    required this.detail,
  });

  factory ScoreItem.fromJson(Map<String, dynamic> json) => ScoreItem(
        name: json['name'] as String? ?? '',
        score: (json['score'] as num?)?.toDouble(),
        weight: (json['weight'] as num?)?.toDouble() ?? 0,
        available: json['available'] as bool? ?? false,
        detail: json['detail'] as String? ?? '',
      );
}

/// 路线生成结果。
class RouteGenResult {
  final List<PlannedRoute> routes;
  final double elapsedS;
  final int apiCalls;
  final Map<String, double> stageTimes;

  const RouteGenResult({
    required this.routes,
    required this.elapsedS,
    required this.apiCalls,
    required this.stageTimes,
  });
}
