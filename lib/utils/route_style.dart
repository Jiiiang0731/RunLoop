import 'package:flutter/material.dart';

/// 路线视觉方案（阶段 J）：白描边 + 渐变主线 + 圆角端点，统一候选页/跑步页风格。
///
/// 线宽单位为 dp（原生按 density 换算为 px）：
/// - 主渐变线 5.5dp，白描边 9.5dp（描边在底层，形成 Google Maps 式包边）；
/// - 未选中路线 3dp 半透明单线，避免喧宾夺主；
/// - 跑步页 GPS 实际轨迹 4.5dp（橙），压在规划路线之上。
class RouteStyle {
  RouteStyle._();

  /// 三条候选路线的渐变色（首 → 尾）。
  static const List<List<Color>> gradients = <List<Color>>[
    <Color>[Color(0xFF2979FF), Color(0xFF00E5FF)], // 蓝 → 青
    <Color>[Color(0xFFFF6D00), Color(0xFFFFD600)], // 橙 → 琥珀
    <Color>[Color(0xFFAA00FF), Color(0xFFFF80AB)], // 紫 → 粉
  ];

  /// 各路线主色（渐变首色，用于卡片/图标/文字）。
  static Color primary(int index) => gradients[index % gradients.length].first;

  static List<Color> gradient(int index) => gradients[index % gradients.length];

  /// 规划路线（跑步页）固定用蓝色渐变。
  static const List<Color> plannedGradient = <Color>[
    Color(0xFF2979FF),
    Color(0xFF00E5FF),
  ];

  /// GPS 实际轨迹颜色。
  static const Color trackColor = Color(0xFFFF3D00);

  // ---------- 线宽（dp） ----------
  static const double coreWidth = 5.5;
  static const double casingWidth = 9.5;
  static const double unselectedWidth = 3.0;
  static const double growthCoreWidth = 5.5;
  static const double growthCasingWidth = 9.5;
  static const double trackCoreWidth = 4.5;
  static const double trackCasingWidth = 8.0;

  // ---------- 描边颜色 ----------
  static const Color casingColor = Color(0xE6FFFFFF); // 白 90%
  static const Color trackCasingColor = Color(0xE6FFFFFF);

  /// 未选中路线：主色降透明度。
  static Color unselectedColor(int index) => primary(index).withAlpha(60);

  // ---------- 叠加顺序（值越大越靠上） ----------
  static const double zUnselected = 5;
  static const double zCasing = 10;
  static const double zCore = 20;
  static const double zTrackCasing = 30;
  static const double zTrack = 40;
}
