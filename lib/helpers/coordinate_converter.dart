import 'dart:math';
import 'package:latlong2/latlong.dart';

/// WGS84 ↔ GCJ-02 坐标转换（对齐 CU coordinate_converter.dart）
class CoordinateConverter {
  static const double _pi = 3.14159265358979324;
  static const double _a = 6378245.0;
  static const double _ee = 0.00669342162296594323;

  static bool _outOfChina(double lat, double lng) {
    return (lng < 72.004 || lng > 137.8347) || (lat < 0.8293 || lat > 55.8271);
  }

  static double _transformLat(double x, double y) {
    double ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * sqrt(x.abs());
    ret += (20.0 * sin(6.0 * x * _pi) + 20.0 * sin(2.0 * x * _pi)) * 2.0 / 3.0;
    ret += (20.0 * sin(y * _pi) + 40.0 * sin(y / 3.0 * _pi)) * 2.0 / 3.0;
    ret += (160.0 * sin(y / 12.0 * _pi) + 320 * sin(y * _pi / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  static double _transformLng(double x, double y) {
    double ret = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * sqrt(x.abs());
    ret += (20.0 * sin(6.0 * x * _pi) + 20.0 * sin(2.0 * x * _pi)) * 2.0 / 3.0;
    ret += (20.0 * sin(x * _pi) + 40.0 * sin(x / 3.0 * _pi)) * 2.0 / 3.0;
    ret += (150.0 * sin(x / 12.0 * _pi) + 300.0 * sin(x / 30.0 * _pi)) * 2.0 / 3.0;
    return ret;
  }

  static LatLng wgs84ToGcj02(LatLng wgs) {
    if (_outOfChina(wgs.latitude, wgs.longitude)) return wgs;
    final dLat = _transformLat(wgs.longitude - 105.0, wgs.latitude - 35.0);
    final dLng = _transformLng(wgs.longitude - 105.0, wgs.latitude - 35.0);
    final radLat = wgs.latitude / 180.0 * _pi;
    var magic = sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = sqrt(magic);
    final latOffset = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * _pi);
    final lngOffset = (dLng * 180.0) / (_a / sqrtMagic * cos(radLat) * _pi);
    return LatLng(wgs.latitude + latOffset, wgs.longitude + lngOffset);
  }
}
