import 'dart:math';

/// 地理计算工具。
const double _earthRadiusMeters = 6371000.0;

double _rad(double deg) => deg * pi / 180.0;

/// 两点间球面距离（米），使用 Haversine 公式。
double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  final double dLat = _rad(lat2 - lat1);
  final double dLng = _rad(lng2 - lng1);
  final double a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return 2 * _earthRadiusMeters * asin(sqrt(a));
}

/// 将「秒/公里」配速格式化为 mm'ss"。
String formatPace(double? secondsPerKm) {
  if (secondsPerKm == null || secondsPerKm.isNaN || secondsPerKm <= 0) {
    return '--\'--"';
  }
  final int total = secondsPerKm.round();
  final int minutes = total ~/ 60;
  final int seconds = total % 60;
  return "$minutes'${seconds.toString().padLeft(2, '0')}\"";
}

/// 将秒数格式化为 h:mm:ss 或 mm:ss。
String formatDuration(int seconds) {
  final int h = seconds ~/ 3600;
  final int m = (seconds % 3600) ~/ 60;
  final int s = seconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 将米格式化为公里字符串（两位小数）。
String formatKm(double meters) => (meters / 1000).toStringAsFixed(2);
