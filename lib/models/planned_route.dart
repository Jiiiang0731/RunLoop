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
      };

  factory PlannedRoute.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawPoly = (json['polyline'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> rawScore = (json['score_components'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> rawSteps = (json['steps'] as List<dynamic>?) ?? <dynamic>[];
    final double errorM = (json['error_m'] as num?)?.toDouble() ?? 0;
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
      steps: rawSteps
          .map((dynamic e) => RouteStep.fromJson(e as Map<String, dynamic>))
          .toList(),
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
