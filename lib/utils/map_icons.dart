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

/// 方向箭头位图（阶段 M-F 6.2 定稿：自然、现代、轻量）。
///
/// 两种形态构成去/返程的「形状 + 颜色」双编码（色觉障碍也可分辨）：
/// - [open] = false：实心箭头 + 白描边（去程，深蓝）；
/// - [open] = true：空心描边箭头 + 白色衬底（返程，青绿）。
/// 方位角永远取折线真实前进方向（调用方传入 Marker.rotation）。
Future<BitmapDescriptor> createArrowIcon(Color color, {bool open = false}) async {
  const double size = 36;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Path path = Path()
    ..moveTo(size / 2, 5)
    ..lineTo(size - 8, size - 7)
    ..lineTo(size / 2, size - 12)
    ..lineTo(8, size - 7)
    ..close();
  if (open) {
    // 空心形态：先铺白色衬底保证任何底图可读，再以主色描边轮廓
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4
        ..strokeJoin = ui.StrokeJoin.round,
    );
  } else {
    // 实心形态：白色描边（略粗）+ 主色填充
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = ui.StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = color);
  }
  final ui.Image image =
      await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
}

/// 转弯标记图标（阶段 N，任务书 6.4）：白色小圆底 + 深色转弯字形
/// （左转/右转/掉头）。尺寸克制，只标真实转弯位置，不遮挡路线主体。
Future<BitmapDescriptor> createTurnMarkerIcon(IconData icon, Color color) async {
  const double size = 38;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Offset c = Offset(size / 2, size / 2);
  canvas.drawCircle(c, size / 2 - 2, Paint()..color = const Color(0x33000000));
  canvas.drawCircle(c, size / 2 - 4.5, Paint()..color = Colors.white);
  final TextPainter tp = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: 21,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: color,
      ),
    ),
  )..layout();
  tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));
  final ui.Image image =
      await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
}

/// 去/返转弯标注图标（阶段 M-F 6.2 重设计）：不再使用「圆圈包裹的人字形」，
/// 改为柔和半透明白色衬底 + 粗圆头人字形——轻量现代，与实心方向箭头
/// 形态区分明确；颜色语义保留（去=青 / 返=紫），配合 [Marker.rotation]
/// 指向行进方向。
Future<BitmapDescriptor> createTurnAnnotationIcon(Color color) async {
  const double size = 30;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Offset c = Offset(size / 2, size / 2);
  // 柔和衬底（70% 白，无硬描边圆圈）：保证浅底图上可读又不喧宾夺主
  canvas.drawCircle(c, size / 2 - 3, Paint()..color = const Color(0xB4FFFFFF));
  final Path chev = Path()
    ..moveTo(8.5, 19.0)
    ..lineTo(size / 2, 9.5)
    ..lineTo(size - 8.5, 19.0);
  canvas.drawPath(
    chev,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.6
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round,
  );
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

/// 平移浏览模式的位置圆点（阶段 L2）：**无方向语义**——真机证实高德
/// Marker 会随地图 bearing 旋转，方向无法保证；跟随时方向由屏幕固定
/// 箭头（RunnerArrow）表达，平移时只显示位置点，宁可不指也不错指。
Future<BitmapDescriptor> createPositionDotIcon(Color color) async {
  const double size = 40;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Offset c = Offset(size / 2, size / 2);
  canvas.drawCircle(c, size / 2 - 4, Paint()..color = const Color(0x33000000));
  canvas.drawCircle(c, size / 2 - 6, Paint()..color = Colors.white);
  canvas.drawCircle(c, size / 2 - 10, Paint()..color = color);
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

/// 箭头数量（阶段 K v2：小巧稀疏——每约 3.5km 一个，限制 2~5 个）。
int arrowCountForLengthMeters(double lengthM) {
  if (lengthM <= 0) return 0;
  final int n = (lengthM / 3500).round();
  return n.clamp(2, 5);
}

// 旧 arrowPointsByDistance 已由 turn_annotations.planArrowPlacements 取代
//（阶段 M-F 6.2：需要去/返 pass 判定与转弯标注避让带，纯距离布点不够）。
