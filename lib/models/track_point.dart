/// 单个 GPS 轨迹点（高德 GCJ-02 坐标）。
class TrackPoint {
  final double latitude;
  final double longitude;
  final double accuracy; // 米
  final double speed; // 米/秒
  final DateTime timestamp;

  const TrackPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lng': longitude,
        'acc': accuracy,
        'spd': speed,
        't': timestamp.millisecondsSinceEpoch,
      };

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        accuracy: (json['acc'] as num).toDouble(),
        speed: (json['spd'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
      );
}
