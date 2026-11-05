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

  /// 规划路线（跑步页）固定用深蓝渐变。
  /// 阶段 M-F v3：双方案对比评审后由「蓝→青」改为「深蓝→亮蓝」——
  /// 原青色尾段在浅色底图/阳光直射下相对亮度对比度仅 1.38（实测，
  /// tools/visual_scheme_metrics.py），新色系最低 3.31、最高 5.54，
  /// 可读性显著提升且保留渐变层次（6.1）。
  static const List<Color> plannedGradient = <Color>[
    Color(0xFF1565C0),
    Color(0xFF1E88E5),
  ];

  /// GPS 实际轨迹颜色。
  static const Color trackColor = Color(0xFFFF3D00);

  /// 已跑完的规划路段（阶段 L 模块 E）：低视觉权重的蓝灰色、半透明、
  /// 更细——与橙色 GPS 轨迹「融合」（轨迹压在上方），又保留规划走向可读性。
  static const Color completedColor = Color(0x9978909C);
  static const double completedWidth = 2.4;
  static const double zCompleted = 8;

  // ---------- 线宽（dp）——阶段 N：类高德导航的醒目粗线 ----------
  // 用户明确：路线必须是画面中最容易识别的元素；2.8dp 细线在真机上
  // 「不像正式导航」。主线 7.0dp + 白描边 10.5dp（保留 3.5dp 白边）。
  static const double coreWidth = 7.0;
  static const double casingWidth = 10.5;
  static const double unselectedWidth = 4.0;
  static const double growthCoreWidth = 7.0;
  static const double growthCasingWidth = 10.5;
  static const double trackCoreWidth = 4.6;
  static const double trackCasingWidth = 7.0;

  // ---------- 去返程并排双轨（阶段 N，任务书 6.3） ----------
  /// 两条轨道相对中心线的像素偏移（配合 metersPerPixel 换算成米，
  /// 仅影响显示；canonical 与 GPS 记录绝不修改）。
  static const double dualTrackOffsetPx = 7.0;

  /// 遮断中心线的白线宽度：主线宽 + 3dp，保证中间留出清晰缝隙。
  static const double dualTrackEraseWidth = coreWidth + 3.0;
  static const double zDualErase = 21;
  static const double zDualCasing = 22;
  static const double zDualCore = 23;

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

  // ---------- 去/返方向箭头（阶段 M-F 6.2：形状+颜色双编码） ----------
  /// 去程：深蓝实心箭头；返程：青绿空心箭头——色觉障碍也可分辨。
  static const Color arrowOutColor = Color(0xFF0D47A1);
  static const Color arrowBackColor = Color(0xFF00695C);

  // ---------- canonical 参考层（阶段 M-F 6.3 / M-D 5.7#9） ----------
  /// 重规划后原规划路线保留为最淡参考线（已完成部分由 GPS 轨迹诚实
  /// 呈现，绝不覆盖）；仅当导航基准 ≠ canonical 时绘制。
  static const Color canonicalRefColor = Color(0x5978909C);
  static const double canonicalRefWidth = 2.0;
  static const double zCanonicalRef = 4;

  // ---------- 重规划连接段（阶段 M-D，任务书 6.3：与原路线明显区分） ----------
  /// 琥珀色主线 + 白描边，压在蓝色剩余路线之上、GPS 轨迹之下。
  static const Color rerouteColor = Color(0xFFFFB300);
  static const double rerouteCoreWidth = 3.0;
  static const double rerouteCasingWidth = 5.0;
  static const double zRerouteCasing = 22;
  static const double zReroute = 24;

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
