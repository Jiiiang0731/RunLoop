/// 单个 GPS 轨迹点（高德 GCJ-02 坐标）。
class TrackPoint {
  final double latitude;
  final double longitude;
  final double accuracy; // 米
  final double speed; // 米/秒
  final DateTime timestamp;

  /// GPS 运动方向（度，0=正北，顺时针）。阶段 L Heading-Up 相机的主方向源。
  /// Android 上仅 locationType==1（GPS）时有值；无效/缺失时为 null。
  /// 旧记录 JSON 无此字段 → 解析为 null（向后兼容）。
  final double? bearing;

  const TrackPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.timestamp,
    this.bearing,
  });

  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lng': longitude,
        'acc': accuracy,
        'spd': speed,
        't': timestamp.millisecondsSinceEpoch,
        if (bearing != null) 'brg': bearing,
      };

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        accuracy: (json['acc'] as num).toDouble(),
        speed: (json['spd'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
        bearing: (json['brg'] as num?)?.toDouble(),
      );
}
