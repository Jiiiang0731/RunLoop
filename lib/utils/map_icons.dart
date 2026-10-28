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

/// 生成一个朝上（北）的小箭头位图，配合 [Marker.rotation] 使用。
Future<BitmapDescriptor> createArrowIcon(Color color) async {
  const double size = 40;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Paint paint = Paint()..color = color;
  final Path path = Path()
    ..moveTo(size / 2, 5)
    ..lineTo(size - 10, size - 8)
    ..lineTo(size / 2, size - 14)
    ..lineTo(10, size - 8)
    ..close();
  canvas.drawPath(path, paint);
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
