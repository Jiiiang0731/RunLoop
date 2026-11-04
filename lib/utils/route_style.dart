import 'package:flutter/material.dart';

/// 路线视觉方案 v2（阶段 K）：细主线 + 轻描边 + 独立绘制层 + 小巧稀疏箭头。
///
/// 线宽单位为 dp（原生按 density 换算为 px）。v1（阶段 J）主线 5.5dp/描边
/// 9.5dp 在真机上过重、遮盖底图道路；v2 收窄为 2.8dp/4.6dp（规范①：主线
/// 2~3dp），描边降为 80% 白。生长动画保留（阶段 J 验收资产）。
///
/// 绘制层（zIndex 越大越靠上）：
///   未选中路线 < 描边 < 主线 < 静态完成层同构 < 标注(160) < 起点(200) < 跑者(300)
/// 数据层约定（规范④）：canonical（服务端折线，永不修改）→ display（静态
/// 主线/描边）→ animation（生长线，完成后延迟一帧移除）→ turnAnnotations
/// （像素级侧偏，纯视觉）→ gpsTrack（跑步页）。
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

  /// 已跑完的规划路段（阶段 L 模块 E）：低视觉权重的蓝灰色、半透明、
  /// 更细——与橙色 GPS 轨迹「融合」（轨迹压在上方），又保留规划走向可读性。
  static const Color completedColor = Color(0x9978909C);
  static const double completedWidth = 2.4;
  static const double zCompleted = 8;

  // ---------- 线宽（dp）——阶段 K 细线化 ----------
  static const double coreWidth = 2.8;
  static const double casingWidth = 4.6;
  static const double unselectedWidth = 2.0;
  static const double growthCoreWidth = 2.8;
  static const double growthCasingWidth = 4.6;
  static const double trackCoreWidth = 3.4;
  static const double trackCasingWidth = 5.2;

  // ---------- 描边颜色（轻描边：80% 白） ----------
  static const Color casingColor = Color(0xCCFFFFFF);
  static const Color trackCasingColor = Color(0xCCFFFFFF);

  /// 未选中路线：主色降透明度（细线更淡，避免喧宾夺主）。
  static Color unselectedColor(int index) => primary(index).withAlpha(46);

  // ---------- 去/返转弯标注（规范③：两种可区分颜色） ----------
  /// 去程标注：深青（teal 700）。
  static const Color turnOutColor = Color(0xFF00796B);

  /// 返程标注：深紫（purple 700）。
  static const Color turnBackColor = Color(0xFF7B1FA2);

  /// 标注距中心线的屏幕像素偏移（随缩放换算为米，两侧对称）。
  static const double turnAnnotationPxOffset = 16.0;

  // ---------- 叠加顺序（值越大越靠上） ----------
  static const double zUnselected = 5;
  static const double zCasing = 10;
  static const double zCore = 20;
  static const double zTrackCasing = 30;
  static const double zTrack = 40;

  // ---------- Marker zIndex ----------
  static const double zArrowMarker = 150;
  static const double zTurnAnnotation = 160;
  static const double zStartMarker = 200;
  static const double zRunnerMarker = 300;
}
