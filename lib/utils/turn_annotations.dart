import 'dart:math' as math;

import 'package:amap_flutter_base/amap_flutter_base.dart';

import '../models/planned_route.dart';
import 'map_icons.dart';

/// 去/返程转弯标注（阶段 K 规范③）——**纯视觉层**。
///
/// 铁律：标注只做「屏幕像素级侧偏定位」，canonical 折线、导航文本、
/// 距离/闭合指标、GPS 轨迹一律不受影响；offsetPerpendicular 的结果
/// 只喂给 Marker.position，永不写回路线数据。
///
/// 数据来源：
/// 1. 服务端 overlaps v2（真实空间配对的 pass1/pass2）→ 在两个 pass 的
///    中点各放一枚标注（去=青，返=紫），分居中心线两侧；
/// 2. 本地 U 形折返检测（死胡同尖头等 overlaps 因 index_gap 漏掉的情况）
///    → 尖点前一枚「去」、后一枚「返」。
/// 像素偏移随缩放换算为米（[metersPerPixel]），随旋转天然不变
/// （地理垂线在屏幕旋转下仍两侧对称）。

/// 标注种类：去程 / 返程。
enum TurnKind { out, back }

class TurnAnnotation {
  const TurnAnnotation({
    required this.id,
    required this.at,
    required this.bearing,
    required this.side,
    required this.kind,
    required this.cumM,
    required this.priorityM,
  });

  /// 稳定 id（同一路线多次重建保持不变，插件走原地更新）。
  final String id;

  /// canonical 折线上的锚点（未偏移）。
  final LatLng at;

  /// 锚点处的行进方位角（度）：用于图标旋转与垂线方向。
  final double bearing;

  /// 侧偏方向：-1 = 行进方向左侧，+1 = 右侧（去/返必须相反）。
  final int side;

  final TurnKind kind;

  /// 锚点累计里程（米）。
  final double cumM;

  /// 排序优先级（对应重复段长度/折返规模，米）。
  final double priorityM;

  String get label => kind == TurnKind.out ? '去程' : '返程';
}

/// Web Mercator 每像素米数（高德同构）：156543.03392 × cos(lat) / 2^zoom。
double metersPerPixel(double zoom, double lat) {
  final double z = zoom.clamp(3.0, 20.0);
  return 156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, z);
}

/// 从 [p] 出发，沿垂直于行进方向 [bearingDeg] 偏移 [meters] 米。
/// [side] = +1 右侧 / -1 左侧。相机旋转不影响两侧对称性（整体同旋）。
LatLng offsetPerpendicular(LatLng p, double bearingDeg, double meters, int side) {
  final double brg = (bearingDeg + 90.0 * side) * math.pi / 180;
  final double dNorth = math.cos(brg) * meters;
  final double dEast = math.sin(brg) * meters;
  final double dLat = dNorth / 110574.0;
  final double dLng = dEast / (111320.0 * math.cos(p.latitude * math.pi / 180));
  return LatLng(p.latitude + dLat, p.longitude + dLng);
}

/// 沿折线的累计里程表。
List<double> cumulativeMeters(List<LatLng> pts) {
  final List<double> cum = <double>[0];
  for (int i = 1; i < pts.length; i++) {
    cum.add(cum[i - 1] + haversineMeters(pts[i - 1], pts[i]));
  }
  return cum;
}

/// U 形折返顶点检测：入边与出边方位角差 ≥ [minFlipDeg] 的顶点。
/// 返回顶点下标（1..n-2）。密集折线上相邻短边噪声由 [minEdgeM] 过滤。
List<int> findUTurnVertices(List<LatLng> pts,
    {double minFlipDeg = 135.0, double minEdgeM = 8.0}) {
  final List<int> out = <int>[];
  if (pts.length < 3) {
    return out;
  }
  for (int i = 1; i < pts.length - 1; i++) {
    // 入边：向前找最近的有效边；出边：向后找
    int a = i - 1;
    while (a >= 0 && haversineMeters(pts[a], pts[i]) < minEdgeM) {
      a--;
    }
    int b = i + 1;
    while (b < pts.length && haversineMeters(pts[i], pts[b]) < minEdgeM) {
      b++;
    }
    if (a < 0 || b >= pts.length) {
      continue;
    }
    final double inB = bearingDeg(pts[a], pts[i]);
    final double outB = bearingDeg(pts[i], pts[b]);
    final double diff = ((inB - outB).abs() + 360) % 360;
    final double flip = diff > 180 ? 360 - diff : diff;
    if (flip >= minFlipDeg) {
      out.add(i);
    }
  }
  return out;
}

/// 由路线构建全部标注（重复段 pass 对 + U 形折返），按优先级去重限量。
///
/// [maxCount]：单条路线标注上限（防密集小折返刷屏）；
/// [minSepM]：两枚标注最小间距（去/返成对者豁免——它们本就同点两侧）。
List<TurnAnnotation> buildTurnAnnotations(
  PlannedRoute route, {
  int maxCount = 12,
  double minSepM = 90.0,
}) {
  final List<LatLng> pts = route.polyline
      .map((List<double> p) => LatLng(p[1], p[0]))
      .toList(growable: false);
  if (pts.length < 4) {
    return <TurnAnnotation>[];
  }
  final List<double> cum = cumulativeMeters(pts);

  double bearingAt(int i) {
    final int a = math.max(0, i - 1);
    final int b = math.min(pts.length - 1, i + 1);
    if (a == b) {
      return 0;
    }
    return bearingDeg(pts[a], pts[b]);
  }

  final List<TurnAnnotation> cand = <TurnAnnotation>[];

  // 1) 重复段 pass 对（服务端真实空间配对）
  int gi = 0;
  for (final OverlapGroup g in route.overlaps) {
    if (g.passes.length == 2) {
      final OverlapPass p1 = g.passes[0];
      final OverlapPass p2 = g.passes[1];
      final int i1 = p1.midIndex.clamp(1, pts.length - 2);
      final int i2 = p2.midIndex.clamp(1, pts.length - 2);
      final double spanM = p1.lengthM > 0
          ? p1.lengthM
          : (cum[math.min(p1.end, pts.length - 1)] - cum[p1.start]);
      cand.add(TurnAnnotation(
        id: 'ta-g$gi-out',
        at: pts[i1],
        bearing: bearingAt(i1),
        side: -1,
        kind: TurnKind.out,
        cumM: p1.cumStartM > 0 || p1.cumEndM > 0
            ? (p1.cumStartM + p1.cumEndM) / 2
            : cum[i1],
        priorityM: spanM,
      ));
      cand.add(TurnAnnotation(
        id: 'ta-g$gi-back',
        at: pts[i2],
        bearing: bearingAt(i2),
        side: 1,
        kind: TurnKind.back,
        cumM: p2.cumStartM > 0 || p2.cumEndM > 0
            ? (p2.cumStartM + p2.cumEndM) / 2
            : cum[i2],
        priorityM: spanM,
      ));
    }
    gi++;
  }

  // 2) U 形折返（尖点前=去，尖点后=返）
  final List<int> apexes = findUTurnVertices(pts);
  int ui = 0;
  for (final int v in apexes) {
    final int io = math.max(1, v - 1);
    final int ib = math.min(pts.length - 2, v + 1);
    final double scale = haversineMeters(pts[io], pts[ib]);
    cand.add(TurnAnnotation(
      id: 'ta-u$ui-out',
      at: pts[io],
      bearing: bearingAt(io),
      side: -1,
      kind: TurnKind.out,
      cumM: cum[io],
      priorityM: math.max(60.0, scale),
    ));
    cand.add(TurnAnnotation(
      id: 'ta-u$ui-back',
      at: pts[ib],
      bearing: bearingAt(ib),
      side: 1,
      kind: TurnKind.back,
      cumM: cum[ib],
      priorityM: math.max(60.0, scale),
    ));
    ui++;
  }

  // 3) 排序（规模大者优先）→ 去重（不同对之间保持间距；成对两侧豁免）
  cand.sort((TurnAnnotation a, TurnAnnotation b) =>
      b.priorityM.compareTo(a.priorityM));
  final List<TurnAnnotation> kept = <TurnAnnotation>[];
  for (final TurnAnnotation a in cand) {
    if (kept.length >= maxCount) {
      break;
    }
    final String pairId = a.id.substring(0, a.id.lastIndexOf('-'));
    bool conflict = false;
    for (final TurnAnnotation k in kept) {
      final String kPair = k.id.substring(0, k.id.lastIndexOf('-'));
      if (kPair == pairId) {
        continue; // 同一对的去/返：同点两侧，豁免
      }
      if (haversineMeters(k.at, a.at) < minSepM) {
        conflict = true;
        break;
      }
    }
    if (!conflict) {
      kept.add(a);
    }
  }
  // 成对完整性：若一对中只留下一枚，丢弃孤枚（两侧标注必须成对出现）
  final Map<String, int> pairCount = <String, int>{};
  for (final TurnAnnotation a in kept) {
    final String pairId = a.id.substring(0, a.id.lastIndexOf('-'));
    pairCount[pairId] = (pairCount[pairId] ?? 0) + 1;
  }
  kept.removeWhere((TurnAnnotation a) {
    final String pairId = a.id.substring(0, a.id.lastIndexOf('-'));
    return (pairCount[pairId] ?? 0) != 2;
  });
  kept.sort((TurnAnnotation a, TurnAnnotation b) => a.cumM.compareTo(b.cumM));
  return kept;
}

// ---------------- 方向箭头布点（阶段 M-F 6.2） ----------------

/// 一枚方向箭头的布点方案（纯视觉：坐标只喂 Marker，不写回路线）。
class ArrowPlacement {
  const ArrowPlacement({
    required this.at,
    required this.bearing,
    required this.cumM,
    required this.back,
  });

  /// 折线上的真实位置（未偏移——6.2：偏移绝不改变真实坐标语义）。
  final LatLng at;

  /// 该点真实前进方向（度，正北顺时针）。
  final double bearing;

  /// 累计里程（米）。
  final double cumM;

  /// true = 返程腿（overlaps pass2 覆盖段）→ 空心箭头样式。
  final bool back;
}

/// 沿折线布放方向箭头（6.2）：
/// - 直行段稀疏均匀（间距 [spacingMeters]，上限 [maxCount]）；
/// - 关键转弯由 [annotations]（转弯标注）负责，箭头在标注 ±[avoidM]
///   米内自动避让——不堆叠、各司其职；
/// - 落在服务端真实 overlaps pass2 里程区间的箭头判定为返程（形状+颜色
///   双编码）；去/返共路段两侧的同时可见性由成对转弯标注保证
///  （offsetPerpendicular ±16px，见 buildTurnAnnotations）。
List<ArrowPlacement> planArrowPlacements(
  List<LatLng> points, {
  required List<OverlapGroup> overlaps,
  required List<TurnAnnotation> annotations,
  double spacingMeters = 2500,
  int maxCount = 8,
  double avoidM = 150,
}) {
  if (points.length < 3 || spacingMeters <= 0 || maxCount <= 0) {
    return <ArrowPlacement>[];
  }
  final List<double> cum = cumulativeMeters(points);
  final List<ArrowPlacement> out = <ArrowPlacement>[];
  double next = spacingMeters;
  for (int i = 1; i < points.length - 1; i++) {
    if (cum[i] < next) continue;
    final LatLng here = points[i];
    final LatLng nextPt = points[i + 1];
    if (here.latitude == nextPt.latitude && here.longitude == nextPt.longitude) {
      continue;
    }
    final double cumHere = cum[i];
    // 转弯标注避让带：箭头绝不与标注堆叠（6.2 直行少放、转弯清晰）
    bool nearAnnotation = false;
    for (final TurnAnnotation a in annotations) {
      if ((a.cumM - cumHere).abs() < avoidM) {
        nearAnnotation = true;
        break;
      }
    }
    if (!nearAnnotation) {
      final bool back = overlaps.any((OverlapGroup g) =>
          g.passes.any((OverlapPass p) =>
              p.pass == 2 &&
              p.cumStartM > 0 &&
              cumHere >= p.cumStartM &&
              cumHere <= p.cumEndM));
      out.add(ArrowPlacement(
        at: here,
        bearing: bearingDeg(here, nextPt),
        cumM: cumHere,
        back: back,
      ));
    }
    next += spacingMeters;
    if (out.length >= maxCount) break;
  }
  return out;
}
