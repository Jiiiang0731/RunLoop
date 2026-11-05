import 'dart:math' as math;

import 'package:amap_flutter_base/amap_flutter_base.dart';

import 'map_icons.dart';

/// 阶段 N：去返程「并排双轨」视觉模块（任务书 6.3 硬性要求）。
///
/// 铁律：这里的所有偏移**只用于显示**——输入折线（canonical/GPS 记录）
/// 一个点都不会被修改；真实导航距离、GPS 轨迹、道路定位完全不受影响。
///
/// 做法：
/// 1. [findFoldPasses] 在折线里找出「原路折返」区间（空间并拢 + 弧长足够）；
/// 2. [offsetPolyline] 把某段折线按屏幕像素换算出的米数做垂线偏移；
/// 3. 调用方把两段分别画在中心线两侧，中间用描边色遮断，得到两条清晰
///    分开的轨道（同一物理道路的双向行程，不是两条虚假街道）。

/// 折返区间：out 指较早经过的一段，back 指后一段。
class FoldPass {
  const FoldPass({
    required this.outStart,
    required this.outEnd,
    required this.backStart,
    required this.backEnd,
    required this.spanM,
  });

  final int outStart;
  final int outEnd;
  final int backStart;
  final int backEnd;
  final double spanM;

  bool get valid => outEnd - outStart >= 2 && backEnd - backStart >= 2;
}

/// 找出折线的原路折返区间（网格近似 + 弧长窗口）。
///
/// - [matchM]：两段空间并拢判定（默认 18m，约一条车道 + 采样误差）；
/// - [minSpanM]：折返弧长下限（太短是路口几何，不是折返）；
/// - [minGapIdx]：两点在折线上的最小间隔，防止相邻点自配对。
List<FoldPass> findFoldPasses(
  List<LatLng> pts, {
  double matchM = 18.0,
  double minSpanM = 60.0,
  int minGapIdx = 6,
  int maxPasses = 6,
}) {
  if (pts.length < minGapIdx * 2) return const <FoldPass>[];
  final List<double> arc = <double>[0];
  for (int i = 1; i < pts.length; i++) {
    arc.add(arc[i - 1] + haversineMeters(pts[i - 1], pts[i]));
  }
  final double total = arc.last;
  if (total < minSpanM * 2) return const <FoldPass>[];

  final double lat0 = pts[pts.length ~/ 2].latitude;
  final double mlng = 111320.0 * math.cos(lat0 * math.pi / 180);
  final double mlat = 110574.0;
  final double x0 = pts[0].longitude * mlng;
  final double y0 = pts[0].latitude * mlat;

  List<double> xy(LatLng p) =>
      <double>[p.longitude * mlng - x0, p.latitude * mlat - y0];
  final List<List<double>> flat = pts.map(xy).toList();

  // 按 2*matchM 分桶，找空间近、弧长远、索引远的点对
  final Map<int, List<int>> grid = <int, List<int>>{};
  final double cell = matchM * 2;
  int key(int gx, int gy) => gx * 100003 + gy;
  for (int i = 0; i < flat.length; i++) {
    final int gx = (flat[i][0] / cell).floor();
    final int gy = (flat[i][1] / cell).floor();
    grid.putIfAbsent(key(gx, gy), () => <int>[]).add(i);
  }

  final List<List<int>> cands = <List<int>>[]; // [i, j, span]
  for (int i = 0; i < flat.length; i++) {
    final int gx = (flat[i][0] / cell).floor();
    final int gy = (flat[i][1] / cell).floor();
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        for (final int j in grid[key(gx + dx, gy + dy)] ?? const <int>[]) {
          if (j - i < minGapIdx) continue;
          final double span = arc[j] - arc[i];
          if (span < minSpanM || span > total * 0.6) continue;
          final double dxm = flat[j][0] - flat[i][0];
          final double dym = flat[j][1] - flat[i][1];
          if (math.sqrt(dxm * dxm + dym * dym) > matchM) continue;
          cands.add(<int>[i, j, span.round()]);
        }
      }
    }
  }
  if (cands.isEmpty) return const <FoldPass>[];
  // 弧长最大者优先，且区间不重叠
  cands.sort((List<int> a, List<int> b) => b[2].compareTo(a[2]));
  final List<bool> taken = List<bool>.filled(pts.length, false);
  final List<FoldPass> out = <FoldPass>[];
  for (final List<int> c in cands) {
    final int i = c[0], j = c[1];
    bool overlap = false;
    for (int k = i; k <= j; k++) {
      if (taken[k]) {
        overlap = true;
        break;
      }
    }
    if (overlap) continue;
    for (int k = i; k <= j; k++) {
      taken[k] = true;
    }
    // 去程 = i..(i + span/2 附近)，返程 = 对应另一侧；用 j 向前回溯相同弧长
    final double half = (arc[j] - arc[i]) / 2.0;
    int mid = i;
    while (mid < j && arc[mid] - arc[i] < half) {
      mid++;
    }
    out.add(FoldPass(
      outStart: i,
      outEnd: mid,
      backStart: mid,
      backEnd: j,
      spanM: arc[j] - arc[i],
    ));
    if (out.length >= maxPasses) break;
  }
  return out;
}

/// 垂线偏移：把折线整体向行进方向 [side]（+1 右 / -1 左）平移 [meters] 米。
///
/// 逐顶点取相邻边的平均方位作垂线方向，保证转角处不塌陷；返回值是**新的**
/// 显示用点列，输入折线不变。
List<LatLng> offsetPolyline(List<LatLng> pts, int side, double meters) {
  if (pts.length < 2 || meters == 0) return List<LatLng>.of(pts);
  final List<LatLng> out = <LatLng>[];
  for (int i = 0; i < pts.length; i++) {
    final int a = i == 0 ? i : i - 1;
    final int b = i == pts.length - 1 ? i : i + 1;
    double brg;
    if (a == b) {
      brg = 0;
    } else {
      brg = _bearing(pts[a], pts[b]);
    }
    // 垂线方向：行进方向 + 90°·side
    final double perp = (brg + 90.0 * side) * math.pi / 180.0;
    final double dNorth = math.cos(perp) * meters;
    final double dEast = math.sin(perp) * meters;
    final double dLat = dNorth / 110574.0;
    final double dLng =
        dEast / (111320.0 * math.cos(pts[i].latitude * math.pi / 180));
    out.add(LatLng(pts[i].latitude + dLat, pts[i].longitude + dLng));
  }
  return out;
}

double _bearing(LatLng a, LatLng b) {
  final double dLng = (b.longitude - a.longitude) * math.pi / 180.0;
  final double lat1 = a.latitude * math.pi / 180.0;
  final double lat2 = b.latitude * math.pi / 180.0;
  final double y = math.sin(dLng) * math.cos(lat2);
  final double x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
  return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
}

/// 一条显示轨道的构建结果。
class DisplayTrack {
  const DisplayTrack({
    required this.points,
    required this.isBack,
    required this.splitOffsetPx,
  });

  final List<LatLng> points;
  final bool isBack;

  /// 相对中心线的像素偏移（正=右侧）。
  final double splitOffsetPx;
}

/// 由「剩余路线折线 + 折返区间」生成两条并排轨道（显示用）。
///
/// [metersPerPx]：当前缩放下的每像素米数（[metersPerPixel]）。
/// [offsetPx]：轨道相对中心线的像素偏移（默认 7px，约等于核心线宽的 1.5 倍）。
List<DisplayTrack> buildDisplayTracks(
  List<LatLng> pts,
  List<FoldPass> folds, {
  required double metersPerPx,
  double offsetPx = 7.0,
}) {
  final List<DisplayTrack> out = <DisplayTrack>[];
  for (final FoldPass f in folds) {
    if (!f.valid) continue;
    final List<LatLng> outSeg = pts.sublist(f.outStart, f.outEnd + 1);
    final List<LatLng> backSeg = pts.sublist(f.backStart, f.backEnd + 1);
    final double m = offsetPx * metersPerPx;
    // 关键：两侧都取「行进方向左侧」——去/返行进方向相反，
    // 同侧取值在绝对空间里自然分居道路两侧（这是同路双向的正确画法）。
    out.add(DisplayTrack(points: offsetPolyline(outSeg, -1, m),
        isBack: false, splitOffsetPx: -offsetPx));
    out.add(DisplayTrack(points: offsetPolyline(backSeg, -1, m),
        isBack: true, splitOffsetPx: -offsetPx));
  }
  return out;
}
