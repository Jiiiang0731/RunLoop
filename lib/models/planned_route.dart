/// 单条候选规划路线。
class PlannedRoute {
  final int seed;
  final double distanceM;
  final double errorM;
  final double closureM;
  final double? score;
  final int nPoints;
  final List<List<double>> polyline; // [[lng, lat], ...]（GCJ-02）
  final List<ScoreItem> scoreComponents;

  const PlannedRoute({
    required this.seed,
    required this.distanceM,
    required this.errorM,
    required this.closureM,
    required this.score,
    required this.nPoints,
    required this.polyline,
    required this.scoreComponents,
  });

  bool get withinTolerance => errorM.abs() <= 500;
  bool get closureOk => closureM < 50;

  factory PlannedRoute.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawPoly = (json['polyline'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> rawScore = (json['score_components'] as List<dynamic>?) ?? <dynamic>[];
    return PlannedRoute(
      seed: json['seed'] as int,
      distanceM: (json['distance_m'] as num).toDouble(),
      errorM: (json['error_m'] as num).toDouble(),
      closureM: (json['closure_m'] as num).toDouble(),
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

  const RouteGenResult({
    required this.routes,
    required this.elapsedS,
    required this.apiCalls,
  });
}
