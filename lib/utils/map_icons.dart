import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';

const double _earthR = 6371000.0;

/// 球面距离（米）。
double haversineMeters(LatLng a, LatLng b) {
  final double dLat = (b.latitude - a.latitude) * math.pi / 180;
  final double dLng = (b.longitude - a.longitude) * math.pi / 180;
  final double lat1 = a.latitude * math.pi / 180;
  final double lat2 = b.latitude * math.pi / 180;
  final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * _earthR * math.asin(math.min(1.0, math.sqrt(h)));
}

/// 生成一个朝上（北）的箭头位图：主色箭形 + 白色描边（任何底图上都清晰），
/// 配合 [Marker.rotation] 使用。
Future<BitmapDescriptor> createArrowIcon(Color color) async {
  const double size = 48;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Path path = Path()
    ..moveTo(size / 2, 6)
    ..lineTo(size - 11, size - 9)
    ..lineTo(size / 2, size - 16)
    ..lineTo(11, size - 9)
    ..close();
  // 先画白色描边（略粗），再画主色填充
  canvas.drawPath(
    path,
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeJoin = ui.StrokeJoin.round,
  );
  canvas.drawPath(path, Paint()..color = color);
  final ui.Image image =
      await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
}

/// 起点/终点标记：绿色圆形徽章 + 白环 + 白色旗形（闭合环线起终点同点）。
Future<BitmapDescriptor> createStartIcon() async {
  const double size = 84;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Offset c = Offset(size / 2, size / 2);
  // 外圈白环 + 阴影感
  canvas.drawCircle(c, size / 2 - 2, Paint()..color = const Color(0x33000000));
  canvas.drawCircle(c, size / 2 - 5, Paint()..color = Colors.white);
  canvas.drawCircle(c, size / 2 - 9, Paint()..color = const Color(0xFF2E7D32));
  // 白色旗形：旗杆 + 三角旗
  final Paint white = Paint()..color = Colors.white;
  final Rect pole = Rect.fromLTWH(size / 2 - 14, size / 2 - 22, 4.5, 44);
  canvas.drawRRect(RRect.fromRectAndRadius(pole, const Radius.circular(2)), white);
  final Path flag = Path()
    ..moveTo(size / 2 - 9, size / 2 - 21)
    ..lineTo(size / 2 + 20, size / 2 - 13)
    ..lineTo(size / 2 - 9, size / 2 - 4)
    ..close();
  canvas.drawPath(flag, white);
  final ui.Image image =
      await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
}

/// 生成「跑者」移动标记：白色圆环 + 主色圆点 + 上方方向小三角（配合 rotation 使用）。
Future<BitmapDescriptor> createRunnerIcon(Color color) async {
  const double size = 44;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Paint fill = Paint()..color = color;
  final Paint ring = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.5;
  final Offset c = const Offset(size / 2, size / 2);
  canvas.drawCircle(c, size / 2 - 5, fill);
  canvas.drawCircle(c, size / 2 - 5, ring);
  final Path notch = Path()
    ..moveTo(size / 2, 1.5)
    ..lineTo(size / 2 + 7, 13)
    ..lineTo(size / 2 - 7, 13)
    ..close();
  canvas.drawPath(notch, Paint()..color = Colors.white);
  final ui.Image image =
      await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
}

/// a→b 的方位角（度，正北为 0，顺时针）。
double bearingDeg(LatLng a, LatLng b) {
  final double lat1 = a.latitude * math.pi / 180;
  final double lat2 = b.latitude * math.pi / 180;
  final double dLon = (b.longitude - a.longitude) * math.pi / 180;
  final double y = math.sin(dLon) * math.cos(lat2);
  final double x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  final double deg = math.atan2(y, x) * 180 / math.pi;
  return (deg + 360) % 360;
}

/// 箭头数量：按路线长度（每约 2.5km 一个，限制 3~8 个）。
int arrowCountForLengthMeters(double lengthM) {
  if (lengthM <= 0) return 0;
  final int n = (lengthM / 2500).round();
  return n.clamp(3, 8);
}

/// 按「沿路线累计距离」均匀取箭头点，方位角取该点的真实前进方向。
List<MapEntry<LatLng, double>> arrowPointsByDistance(
  List<LatLng> points, {
  double spacingMeters = 2500,
  int maxCount = 8,
}) {
  if (points.length < 3 || spacingMeters <= 0) {
    return <MapEntry<LatLng, double>>[];
  }
  final List<MapEntry<LatLng, double>> out = <MapEntry<LatLng, double>>[];
  double cumulative = 0;
  double next = spacingMeters;
  for (int i = 1; i < points.length - 1; i++) {
    cumulative += haversineMeters(points[i - 1], points[i]);
    if (cumulative < next) continue;
    final LatLng here = points[i];
    final LatLng nextPt = points[i + 1];
    if (here.latitude == nextPt.latitude && here.longitude == nextPt.longitude) {
      continue;
    }
    out.add(MapEntry<LatLng, double>(here, bearingDeg(here, nextPt)));
    next += spacingMeters;
    if (out.length >= maxCount) break;
  }
  return out;
}
