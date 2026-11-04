/// 解析后的定位结果。
class LocationResult {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double speed;
  final int locationType; // 1=GPS，其余为网络/缓存等
  final DateTime timestamp;
  final int? errorCode;
  final String? errorInfo;

  /// GPS 运动方向（度）。插件文档：Android 仅 locationType==1 时有值，
  /// 其余场景原生层可能给 0.0 假值——解析时统一按「仅 GPS 定位才有效」处理，
  /// 无效即 null（Heading-Up 相机据此决定是否采用，绝不盲信）。
  final double? bearing;

  const LocationResult({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.locationType,
    required this.timestamp,
    this.errorCode,
    this.errorInfo,
    this.bearing,
  });

  bool get hasError => errorCode != null && errorCode != 0;

  /// 从高德定位回调的 Map 解析。
  factory LocationResult.fromMap(Map<String, Object> map) {
    final int? errorCode = _toInt(map['errorCode']);
    final int locationType = _toInt(map['locationType']) ?? -1;
    return LocationResult(
      latitude: _toDouble(map['latitude']) ?? 0,
      longitude: _toDouble(map['longitude']) ?? 0,
      accuracy: _toDouble(map['accuracy']) ?? 0,
      speed: _toDouble(map['speed']) ?? 0,
      locationType: locationType,
      timestamp: _parseTime(map['locationTime']) ?? DateTime.now(),
      errorCode: errorCode,
      errorInfo: map['errorInfo'] as String?,
      bearing: locationType == 1 ? _toDouble(map['bearing']) : null,
    );
  }

  static double? _toDouble(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static int? _toInt(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static DateTime? _parseTime(Object? v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString());
  }
}
