import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';

/// 生成一个朝上（北）的箭头位图，配合 [Marker.rotation] 使用。
Future<BitmapDescriptor> createArrowIcon(Color color) async {
  const double size = 64;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Paint paint = Paint()
    ..color = color
    ..style = PaintingStyle.fill;
  final Path path = Path()
    ..moveTo(size / 2, 4)
    ..lineTo(size - 8, size - 6)
    ..lineTo(size / 2, size - 18)
    ..lineTo(8, size - 6)
    ..close();
  canvas.drawPath(path, paint);
  final ui.Image image =
      await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
}

/// 计算 a→b 的方位角（度，正北为 0，顺时针）。
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

/// 在折线上均匀选取若干点（按索引间隔），返回 (点, 方位角)。
///
/// 方位角由该点与下一个点的真实前进方向计算，不随机。
List<MapEntry<LatLng, double>> arrowPointsAlong(
  List<LatLng> points, {
  int count = 5,
}) {
  if (points.length < 3 || count <= 0) return <MapEntry<LatLng, double>>[];
  final int step = math.max(2, points.length ~/ (count + 1));
  final List<MapEntry<LatLng, double>> out = <MapEntry<LatLng, double>>[];
  for (int i = step; i < points.length - 1; i += step) {
    final LatLng here = points[i];
    final LatLng next = points[i + 1];
    if (here.latitude == next.latitude && here.longitude == next.longitude) {
      continue;
    }
    out.add(MapEntry<LatLng, double>(here, bearingDeg(here, next)));
    if (out.length >= count) break;
  }
  return out;
}
