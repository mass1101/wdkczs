import 'package:latlong2/latlong.dart';

import '../models/enums.dart';

/// 生成围栏 id（时间戳，不引入 uuid 依赖）
String newGeofenceId() =>
    'f${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

/// 电子围栏模型（对齐 CU geofence.dart，坐标用 latlong2 LatLng）
class Geofence {
  final String id;
  String name;
  String label;
  int slotNumber; // 1 起
  bool enabled;
  List<LatLng> points;
  int colorValue;
  bool cardLibraryMode;
  String? icCardId; // SaveCard.id
  String? idCardId; // 预留：ID 卡位
  bool rollingCode;

  Geofence({
    required this.id,
    required this.name,
    required this.label,
    required this.slotNumber,
    this.enabled = true,
    required this.points,
    this.colorValue = 0xFF2196F3,
    this.cardLibraryMode = false,
    this.icCardId,
    this.idCardId,
    this.rollingCode = false,
  });

  Geofence copyWith({
    String? name,
    String? label,
    int? slotNumber,
    bool? enabled,
    List<LatLng>? points,
    int? colorValue,
    bool? cardLibraryMode,
    String? icCardId,
    String? idCardId,
    bool? rollingCode,
  }) => Geofence(
    id: id,
    name: name ?? this.name,
    label: label ?? this.label,
    slotNumber: slotNumber ?? this.slotNumber,
    enabled: enabled ?? this.enabled,
    points: points ?? List.from(this.points),
    colorValue: colorValue ?? this.colorValue,
    cardLibraryMode: cardLibraryMode ?? this.cardLibraryMode,
    icCardId: icCardId ?? this.icCardId,
    idCardId: idCardId ?? this.idCardId,
    rollingCode: rollingCode ?? this.rollingCode,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'label': label,
    'slotNumber': slotNumber,
    'enabled': enabled,
    'colorValue': colorValue,
    'cardLibraryMode': cardLibraryMode,
    'icCardId': icCardId,
    'idCardId': idCardId,
    'rollingCode': rollingCode,
    'points': points
        .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
        .toList(),
  };

  factory Geofence.fromJson(Map<String, dynamic> json) => Geofence(
    id: json['id'] as String,
    name: json['name'] as String,
    label: json['label'] as String? ?? '',
    slotNumber: json['slotNumber'] as int,
    enabled: json['enabled'] as bool? ?? true,
    colorValue: json['colorValue'] as int? ?? 0xFF2196F3,
    cardLibraryMode: json['cardLibraryMode'] as bool? ?? false,
    icCardId: json['icCardId'] as String? ?? json['cardId'] as String?,
    idCardId: json['idCardId'] as String?,
    rollingCode: json['rollingCode'] as bool? ?? false,
    points: (json['points'] as List)
        .map(
          (p) => LatLng(
            (p['latitude'] as num).toDouble(),
            (p['longitude'] as num).toDouble(),
          ),
        )
        .toList(),
  );
}

/// 围栏匹配（射线法，对齐 CU geofence_matcher.dart）
class GeofenceMatcher {
  static bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    var j = polygon.length - 1;
    var inside = false;
    for (var i = 0; i < polygon.length; i++) {
      final pi = polygon[i];
      final pj = polygon[j];
      if ((pi.latitude > point.latitude) != (pj.latitude > point.latitude)) {
        final intersectLng =
            pj.longitude +
            (point.latitude - pj.latitude) /
                (pi.latitude - pj.latitude) *
                (pi.longitude - pj.longitude);
        if (point.longitude < intersectLng) {
          inside = !inside;
        }
      }
      j = i;
    }
    return inside;
  }

  /// 返回命中的最后一个已启用围栏
  static Geofence? findMatchingFence(LatLng position, List<Geofence> fences) {
    Geofence? lastMatch;
    for (final fence in fences) {
      if (!fence.enabled) continue;
      if (fence.points.length < 3) continue;
      if (isPointInPolygon(position, fence.points)) {
        lastMatch = fence;
      }
    }
    return lastMatch;
  }
}

/// 判断卡是否 HF（用于滚动码轮询，仅 HF 可读回）
bool isHfCard(TagType tag) => !isLf(tag);

bool isLf(TagType tag) =>
    tag == TagType.em4100 ||
    tag == TagType.electra ||
    tag == TagType.hidProx ||
    tag == TagType.viking ||
    tag == TagType.pac ||
    tag == TagType.ioProx ||
    tag == TagType.idteck;
